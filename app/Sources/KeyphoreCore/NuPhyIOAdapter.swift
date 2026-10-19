import Foundation

public protocol Air65ReportTransport: AnyObject {
    func send(_ report: [UInt8]) throws
    func receive(timeout: TimeInterval) throws -> [UInt8]?
}

public protocol Air65TransportDiscovering: AnyObject {
    func discover() throws -> [HIDDeviceDescriptor]
    func open(_ descriptor: HIDDeviceDescriptor) throws -> any Air65ReportTransport
    func resetDiscoveryState()
}

public protocol CompanionLightingValidating: AnyObject {
    func validate(_ behavior: LightingBehavior) throws
}

public struct LightingCapabilityError: Error, Equatable, Sendable {
    public let model: SupportedKeyboardModel
    public let reason: String
}

public enum VisualConfirmation: String, Codable, Equatable, Sendable {
    case notRequested
    case confirmed
    case rejected
}

public enum UnmanagedZoneProtection: String, Codable, Sendable {
    case readback
    case untouchedProtocolChannel
}

public struct NuPhyIOEvidence: Equatable, Sendable {
    public let protocolReadbackSucceeded: Bool
    public let visualConfirmation: VisualConfirmation
    public let mainState: [UInt8]
    public let rhythmBefore: [UInt8]
    public let rhythmAfter: [UInt8]
    public let unmanagedZonesPreserved: Bool
    public let unmanagedZoneProtection: UnmanagedZoneProtection

    public init(
        protocolReadbackSucceeded: Bool,
        visualConfirmation: VisualConfirmation,
        mainState: [UInt8],
        rhythmBefore: [UInt8],
        rhythmAfter: [UInt8],
        unmanagedZonesPreserved: Bool? = nil,
        unmanagedZoneProtection: UnmanagedZoneProtection = .readback
    ) {
        self.protocolReadbackSucceeded = protocolReadbackSucceeded
        self.visualConfirmation = visualConfirmation
        self.mainState = mainState
        self.rhythmBefore = rhythmBefore
        self.rhythmAfter = rhythmAfter
        self.unmanagedZonesPreserved = unmanagedZonesPreserved ?? (rhythmBefore == rhythmAfter)
        self.unmanagedZoneProtection = unmanagedZoneProtection
    }
}

public enum NuPhyIOAdapterError: Error, Equatable, Sendable {
    case unsupportedEffect
    case unmanagedZoneChanged(LightingZone)
    case responseTimedOut
    case invalidLightState
    case mainBacklightReadbackMismatch
    case rhythmLightChanged
    case air75ReadbackMismatch(expected: [UInt8], actual: [UInt8])
}

public final class NuPhyIOAdapter: CompanionLightingApplying, CompanionLightingVerifying,
    CompanionLightingRecovering, CompanionLightingEvidenceApplying, CompanionKeyboardIdentifying,
    CompanionLightingValidating, CompanionKeyboardSelecting, ExperimentalKeyboardLighting
{
    public static let responseTimeout: TimeInterval = 1

    private let discovery: any Air65TransportDiscovering
    public var experimentalStore: ExperimentalKeyboardStore?
    private var experimentalIdentity: ExperimentalKeyboardIdentity?
    private let makeChallenge: () -> [UInt8]
    private var ownedDescriptor: HIDDeviceDescriptor?
    private var ownedTransport: (any Air65ReportTransport)?
    public private(set) var connectedModel: SupportedKeyboardModel?
    public private(set) var selectedModel: SupportedKeyboardModel?
    private var discoveryNeedsReset = false

    public convenience init(discovery: any Air65TransportDiscovering) {
        self.init(discovery: discovery, challenge: Self.randomChallenge)
    }

    public init(
        discovery: any Air65TransportDiscovering,
        challenge: @escaping () -> [UInt8]
    ) {
        self.discovery = discovery
        makeChallenge = challenge
    }

    public func applyAndVerify(_ behavior: LightingBehavior) throws -> NuPhyIOEvidence {
        do {
            let transport = try acquireTransport(for: behavior)
            if connectedModel == .air75V2 {
                return try VIALightingAdapter(transport: transport).applyAndVerify(behavior)
            }
            guard let model = connectedModel,
                  let profile = experimentalIdentity?.model.flatMap(NuPhyLightingProfile.experimental)
                    ?? NuPhyLightingProfile.verified(for: model) else {
                throw ExperimentalKeyboardError.incompatibleState
            }
            return try applyAndVerify(behavior, using: transport, profile: profile)
        } catch {
            let identity = experimentalIdentity
            invalidateAfter(error)
            if let identity, let failure = error as? NuPhyIOAdapterError,
               failure != .responseTimedOut, let experimentalStore,
               var record = try? experimentalStore.record(for: identity), record.phase == .enabled {
                record.phase = .revoking
                if (try? experimentalStore.replace(record, expecting: .enabled)) != nil {
                    let off = try? applyExperimental(.off, identity: identity)
                    record.phase = .failed
                    record.signalOffVerified = off?.protocolReadbackSucceeded == true
                    try? experimentalStore.replace(record, expecting: .revoking)
                }
            }
            throw error
        }
    }

    public func validate(_ behavior: LightingBehavior) throws {
        do {
            _ = try acquireTransport(for: behavior)
        } catch {
            invalidateAfter(error)
            throw error
        }
    }

    private func validateBehavior(_ behavior: LightingBehavior, model: SupportedKeyboardModel?) throws {
        if model == .air75V2 { try VIALightingAdapter.validate(behavior) }
        else {
            for zone in LightingZone.allCases {
                _ = try zoneState(for: behavior.behavior(for: zone), zone: zone)
            }
        }
    }

    public func selectTarget(_ model: SupportedKeyboardModel?) throws {
        try KeyboardSelectionStore.validate(model)
        guard selectedModel != model else { return }
        invalidateTransport()
        selectedModel = model
    }

    public func keyboardInventory() throws -> [KeyboardInventoryEntry] {
        resetDiscoveryIfNeeded()
        let devices = try discovery.discover()
        return SupportedKeyboardModel.selectableModels.compactMap { model in
            let count = devices.filter { SupportedKeyboardModel.identify($0) == model }.count
            return count == 0 ? nil : KeyboardInventoryEntry(model: model, count: count)
        }
    }

    private func resetDiscoveryIfNeeded() {
        if discoveryNeedsReset {
            discovery.resetDiscoveryState()
            discoveryNeedsReset = false
        }
    }

    private func invalidateAfter(_ error: Error) {
        invalidateTransport()
        // A rejected configuration still identifies the connected keyboard for settings.
        connectedModel = (error as? LightingCapabilityError)?.model
    }

    private func applyAndVerify(
        _ behavior: LightingBehavior,
        using transport: any Air65ReportTransport,
        profile: NuPhyLightingProfile,
        captureReadback: (([UInt8]) -> Void)? = nil,
        trace: ((String, [UInt8]) -> Void)? = nil
    ) throws -> NuPhyIOEvidence {
        var states = try LightingZone.allCases.map { try zoneState(for: behavior.behavior(for: $0), zone: $0) }
        let key = try startTemporarySession(transport, challenge: makeChallenge())
        let initial = try readLightState(transport, key: key, profile: profile)
        trace?("before", initial)
        for (index, zone) in LightingZone.allCases.enumerated() where states[index]?[1] == 0 {
            var off = Array(initial[profile.range(for: zone)])
            off[1] = 0
            states[index] = off
        }
        var configurationStates = states
        var brightnessWrites: [(UInt16, UInt8)] = []
        var configurationWritten = false
        for (index, zone) in LightingZone.allCases.enumerated() {
            guard let requested = states[index] else { continue }
            let range = profile.range(for: zone)
            guard Array(initial[range]) != requested else { continue }
            if requested[1] == 0 {
                // An off request never queues a new mode or color configuration.
                configurationStates[index] = Array(initial[range])
            } else {
                try exchange(transport, request: .write(address: UInt16(range.lowerBound), payload: requested), key: key)
                configurationWritten = true
            }
            brightnessWrites.append((UInt16(range.lowerBound + 1), requested[1]))
        }
        if configurationWritten {
            _ = try settledState(transport, key: key, profile: profile, expected: configurationStates,
                                 initial: initial, captureReadback: captureReadback, trace: trace)
        }
        // NuPhyIO applies brightness separately. Applying it before the asynchronous full
        // configuration settles can scale RGB transiently and race the pending configuration.
        for (address, brightness) in brightnessWrites {
            try exchange(transport, request: .write(address: address, payload: [brightness]), key: key)
        }
        let verified = try settledState(transport, key: key, profile: profile, expected: states,
                                       initial: initial, captureReadback: captureReadback, trace: trace)
        return NuPhyIOEvidence(
            protocolReadbackSucceeded: true, visualConfirmation: .notRequested,
            mainState: Array(verified[0..<9]), rhythmBefore: Array(initial[9..<17]),
            rhythmAfter: Array(verified[9..<17]), unmanagedZonesPreserved: true
        )
    }

    private func settledState(
        _ transport: any Air65ReportTransport, key: NuPhySessionKey, profile: NuPhyLightingProfile,
        expected: [[UInt8]?], initial: [UInt8], captureReadback: (([UInt8]) -> Void)?,
        trace: ((String, [UInt8]) -> Void)?
    ) throws -> [UInt8] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        func remainingSeconds() -> Double {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            return Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        }
        var matchingReads = 0
        while true {
            let remaining = remainingSeconds()
            guard remaining > 0 else { throw NuPhyIOAdapterError.mainBacklightReadbackMismatch }
            let current = try readLightState(transport, key: key, profile: profile, timeout: remaining)
            captureReadback?(current)
            trace?("readback", current)
            var matches = true
            for (zone, requested) in zip(LightingZone.allCases, expected) {
                let range = profile.range(for: zone)
                if let requested {
                    matches = (Array(current[range]) == requested) && matches
                } else if initial[range] != current[range] {
                    throw NuPhyIOAdapterError.unmanagedZoneChanged(zone)
                }
            }
            matchingReads = matches ? matchingReads + 1 : 0
            if matchingReads == 2 { return current }
            Thread.sleep(forTimeInterval: max(0, min(remainingSeconds(), 0.025)))
        }
    }

    public func apply(_ behavior: LightingBehavior) throws {
        _ = try applyAndVerify(behavior)
    }

    public func inspectAir75MainAndSideState() throws -> [UInt8] {
        let transport = try openAir75ForAcceptance()
        let key = try startTemporarySession(transport, challenge: makeChallenge())
        return try readLightState(transport, key: key, profile: .air75V3)
    }

    public func inspectAir75V2State() throws -> [UInt8] {
        do {
            let transport = try acquireTransport()
            guard connectedModel == .air75V2 else { throw Air65DeviceSelectionError.unsupported }
            return try VIALightingAdapter(transport: transport).inspect()
        } catch {
            invalidateAfter(error)
            throw error
        }
    }

    public func previewAir75MainBacklight(
        trace: ((String, [UInt8]) -> Void)? = nil,
        onStep: (String) -> Void
    ) throws {
        let transport = try openAir75ForAcceptance()
        let off = LightingBehavior.off
        let steps: [(String, SignalColor?)] = [
            ("blue", SignalColor(red: 0, green: 0, blue: 255)),
            ("orange", SignalColor(red: 255, green: 132, blue: 0)),
            ("green", SignalColor(red: 0, green: 255, blue: 0)),
            ("off", nil),
        ]
        var lastExpected: [UInt8] = []
        var lastReadback: [UInt8] = []
        do {
            var protectedState: [UInt8]?
            for (name, color) in steps {
                let behavior: LightingBehavior = color.map {
                    LightingBehavior(backlight: .signal(ZoneAppearance(effect: .backlightStatic, color: $0,
                                             brightness: SignalBrightness(percent: 30)!)), strip: .unmanaged)
                } ?? .off
                lastExpected = try zoneState(for: behavior.backlight, zone: .backlight)!
                let evidence = try applyAndVerify(
                    behavior, using: transport,
                    // Air75 scales RGB again when brightness is written separately.
                    profile: .air75V3,
                    captureReadback: { lastReadback = $0 }, trace: trace
                )
                if let protectedState, evidence.rhythmBefore != protectedState {
                    throw NuPhyIOAdapterError.rhythmLightChanged
                }
                protectedState = evidence.rhythmAfter
                onStep(name)
            }
        } catch {
            _ = try? applyAndVerify(off, using: transport, profile: .air75V3)
            if error as? NuPhyIOAdapterError == .mainBacklightReadbackMismatch {
                throw NuPhyIOAdapterError.air75ReadbackMismatch(expected: lastExpected, actual: lastReadback)
            }
            throw error
        }
    }

    private func openAir75ForAcceptance() throws -> any Air65ReportTransport {
        let matches = try discovery.discover().filter {
            $0.vendorID == 0x19f5 && $0.productID == 0x1028
                && ["Air75 V3", "NuPhy Air75 V3"].contains($0.product)
                && $0.bus == .usb && $0.interfaceNumber == 3
                && $0.usagePage == 1 && $0.usage == 0
        }
        guard !matches.isEmpty else { throw Air65DeviceSelectionError.notFound }
        guard matches.count == 1 else { throw Air65DeviceSelectionError.ambiguous }
        return try discovery.open(matches[0])
    }

    public func displays(_ behavior: LightingBehavior) throws -> Bool {
        do {
            let transport = try acquireTransport(for: behavior)
            if connectedModel == .air75V2 {
                return try VIALightingAdapter(transport: transport).displays(behavior)
            }
            guard let model = connectedModel,
                  let profile = experimentalIdentity?.model.flatMap(NuPhyLightingProfile.experimental)
                    ?? NuPhyLightingProfile.verified(for: model) else { throw ExperimentalKeyboardError.incompatibleState }
            let challenge = makeChallenge()
            let key = try startTemporarySession(transport, challenge: challenge)
            let current = try readLightState(transport, key: key, profile: profile)
            return try LightingZone.allCases.allSatisfy { zone in
                guard let requested = try zoneState(for: behavior.behavior(for: zone), zone: zone) else { return true }
                if requested[1] == 0 { return current[profile.range(for: zone).lowerBound + 1] == 0 }
                return zoneMatches(Array(current[profile.range(for: zone)]), expected: requested)
            }
        } catch {
            invalidateAfter(error)
            throw error
        }
    }

    public func invalidateTransport() {
        ownedTransport = nil
        ownedDescriptor = nil
        connectedModel = nil
        experimentalIdentity = nil
        discoveryNeedsReset = true
    }

    private func acquireTransport(for behavior: LightingBehavior? = nil) throws -> any Air65ReportTransport {
        if let experimentalIdentity {
            guard try experimentalStore?.record(for: experimentalIdentity)?.phase == .enabled else {
                invalidateTransport()
                throw ExperimentalKeyboardError.consentRequired
            }
            // Re-enumeration prevents a cached approval surviving a firmware or topology change.
            guard let current = try experimentalDevice(), ExperimentalKeyboardIdentity(current) == experimentalIdentity else {
                invalidateTransport()
                throw ExperimentalKeyboardError.deviceChanged
            }
        }
        if let ownedTransport {
            if let behavior { try validateBehavior(behavior, model: connectedModel) }
            if experimentalIdentity == nil {
                let authorized = try discovery.discover().filter { device in
                    if let selectedModel { return SupportedKeyboardModel.identify(device) == selectedModel }
                    if SupportedKeyboardModel.identify(device) != nil { return true }
                    guard let identity = ExperimentalKeyboardIdentity(device) else { return false }
                    return (try? experimentalStore?.record(for: identity)?.phase) == .enabled
                }
                guard authorized.count == 1 else {
                    invalidateTransport()
                    throw authorized.isEmpty ? Air65DeviceSelectionError.notFound : .ambiguous
                }
                guard authorized[0].id == ownedDescriptor?.id else {
                    invalidateTransport()
                    throw ExperimentalKeyboardError.deviceChanged
                }
            }
            return ownedTransport
        }
        resetDiscoveryIfNeeded()
        let devices = try discovery.discover()
        var selected: HIDDeviceDescriptor
        do {
            selected = try Air65DeviceSelector.select(from: devices, preferredModel: selectedModel)
            if selectedModel == nil, let experimentalStore,
               devices.contains(where: { device in
                   guard let identity = ExperimentalKeyboardIdentity(device) else { return false }
                   return (try? experimentalStore.record(for: identity)?.phase) == .enabled
               }) { throw Air65DeviceSelectionError.ambiguous }
        } catch Air65DeviceSelectionError.unverified {
            guard let device = try experimentalDevice(), let identity = ExperimentalKeyboardIdentity(device),
                  try experimentalStore?.record(for: identity)?.phase == .enabled else {
                throw Air65DeviceSelectionError.unverified(devices.filter {
                    CandidateKeyboardModel.identify(vendorID: $0.vendorID, productID: $0.productID, product: $0.product) != nil
                }.map(UnverifiedKeyboardInterface.init))
            }
            selected = device
            experimentalIdentity = identity
        }
        let model = SupportedKeyboardModel.identify(selected)
            ?? experimentalIdentity?.model.map { SupportedKeyboardModel(rawValue: $0.rawValue) }
        if let behavior { try validateBehavior(behavior, model: model) }
        let transport = try discovery.open(selected)
        ownedTransport = transport
        ownedDescriptor = selected
        connectedModel = model
        return transport
    }

    public func experimentalDevice() throws -> HIDDeviceDescriptor? {
        guard selectedModel == nil else { return nil }
        let devices = try discovery.discover()
        let controls = devices.filter {
            $0.vendorID == 0x19f5 && $0.bus == .usb && $0.interfaceNumber == 3
                && $0.usagePage == 1 && $0.usage == 0
                && ($0.productID == 0x102b || CandidateKeyboardModel.identify(vendorID: $0.vendorID, productID: $0.productID, product: $0.product) != nil)
        }
        guard controls.count == 1, ExperimentalKeyboardIdentity(controls[0]) != nil else { return nil }
        return controls[0]
    }

    public func inspectExperimental(_ identity: ExperimentalKeyboardIdentity) throws -> [UInt8] {
        guard identity.isEligible, let device = try experimentalDevice(), ExperimentalKeyboardIdentity(device) == identity else {
            throw ExperimentalKeyboardError.deviceChanged
        }
        let transport = try discovery.open(device)
        let key = try startTemporarySession(transport, challenge: makeChallenge())
        let state = try readLightState(transport, key: key, profile: NuPhyLightingProfile.experimental(for: identity.model!)!)
        guard state[0] <= 30, state[1] <= 100, state[4] <= 1, state[10] <= 100 else {
            throw ExperimentalKeyboardError.incompatibleState
        }
        return state
    }

    public func applyExperimental(_ behavior: LightingBehavior, identity: ExperimentalKeyboardIdentity) throws -> NuPhyIOEvidence {
        guard identity.isEligible, let profile = identity.model.flatMap(NuPhyLightingProfile.experimental),
              let phase = try experimentalStore?.record(for: identity)?.phase,
              phase == .testing || (phase == .revoking && behavior == .off),
              let device = try experimentalDevice(), ExperimentalKeyboardIdentity(device) == identity else {
            throw ExperimentalKeyboardError.consentRequired
        }
        let transport = try discovery.open(device)
        return try applyAndVerify(behavior, using: transport, profile: profile)
    }

    private func startTemporarySession(
        _ transport: any Air65ReportTransport,
        challenge: [UInt8]
    ) throws -> NuPhySessionKey {
        try transport.send(NuPhyProtocol.temporarySessionRequest(challenge: challenge))
        let deadline = Date().addingTimeInterval(Self.responseTimeout)
        while Date() < deadline {
            let remaining = max(0.001, deadline.timeIntervalSinceNow)
            guard let response = try transport.receive(timeout: remaining) else {
                throw NuPhyIOAdapterError.responseTimedOut
            }
            if let key = try? NuPhyProtocol.validateTemporarySession(
                response,
                challenge: challenge
            ) {
                return key
            }
        }
        throw NuPhyIOAdapterError.responseTimedOut
    }

    private func readLightState(
        _ transport: any Air65ReportTransport,
        key: NuPhySessionKey,
        profile: NuPhyLightingProfile,
        timeout: TimeInterval = NuPhyIOAdapter.responseTimeout
    ) throws -> [UInt8] {
        let payload = try exchange(
            transport,
            request: .read(address: profile.stateAddress, length: UInt8(profile.stateLength)),
            key: key, timeout: timeout
        )
        guard payload.count == profile.stateLength else {
            throw NuPhyIOAdapterError.invalidLightState
        }
        return payload
    }

    @discardableResult
    private func exchange(
        _ transport: any Air65ReportTransport,
        request: NuPhyRequest,
        key: NuPhySessionKey,
        timeout: TimeInterval = NuPhyIOAdapter.responseTimeout
    ) throws -> [UInt8] {
        try transport.send(request.encoded(using: key))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = max(0.001, deadline.timeIntervalSinceNow)
            guard let response = try transport.receive(timeout: remaining) else {
                throw NuPhyIOAdapterError.responseTimedOut
            }
            if request.isResponseCandidate(response, key: key) {
                return try NuPhyProtocol.validate(response, for: request, key: key)
            }
        }
        throw NuPhyIOAdapterError.responseTimedOut
    }

    private func zoneState(for behavior: ZoneLightingBehavior, zone: LightingZone) throws -> [UInt8]? {
        switch behavior {
        case .unmanaged:
            return nil
        case .off:
            return zone == .backlight ? [3, 0, 3, 0, 1, 0, 0, 0, 0] : [2, 0, 2, 0, 0, 0, 0, 0]
        case .signal(let appearance):
            guard appearance.effect.zone == zone, let wireID = appearance.effect.wireID else {
                throw NuPhyIOAdapterError.unsupportedEffect
            }
            let flag: UInt8 = !appearance.effect.supportsColor || (appearance.effect.supportsMulticolor && appearance.colorMode == .multicolor) ? 1 : 0
            var state = [wireID, appearance.brightness.percent, 4 - appearance.speed.level]
            if zone == .backlight { state.append(appearance.effect.directionAxis == nil ? 0 : appearance.direction.rawValue) }
            state += [flag, 0, appearance.color.red, appearance.color.green, appearance.color.blue]
            return state
        }
    }

    private func zoneMatches(_ state: [UInt8], expected: [UInt8]) -> Bool {
        guard state.count == expected.count else { return false }
        return state == expected
    }

    private static func randomChallenge() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<NuPhyProtocol.payloadLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
