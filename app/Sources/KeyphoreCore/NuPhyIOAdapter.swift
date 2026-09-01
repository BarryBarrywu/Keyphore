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

public enum VisualConfirmation: String, Codable, Equatable, Sendable {
    case notRequested
    case confirmed
    case rejected
}

public struct NuPhyIOEvidence: Equatable, Sendable {
    public let protocolReadbackSucceeded: Bool
    public let visualConfirmation: VisualConfirmation
    public let mainState: [UInt8]
    public let rhythmBefore: [UInt8]
    public let rhythmAfter: [UInt8]

    public init(
        protocolReadbackSucceeded: Bool,
        visualConfirmation: VisualConfirmation,
        mainState: [UInt8],
        rhythmBefore: [UInt8],
        rhythmAfter: [UInt8]
    ) {
        self.protocolReadbackSucceeded = protocolReadbackSucceeded
        self.visualConfirmation = visualConfirmation
        self.mainState = mainState
        self.rhythmBefore = rhythmBefore
        self.rhythmAfter = rhythmAfter
    }
}

public enum NuPhyIOAdapterError: Error, Equatable, Sendable {
    case unsupportedPattern
    case responseTimedOut
    case invalidLightState
    case mainBacklightReadbackMismatch
    case rhythmLightChanged
}

public final class NuPhyIOAdapter: CompanionLightingApplying, CompanionLightingVerifying,
    CompanionLightingRecovering, CompanionLightingEvidenceApplying
{
    public static let responseTimeout: TimeInterval = 1

    private let discovery: any Air65TransportDiscovering
    private let makeChallenge: () -> [UInt8]
    private var ownedTransport: (any Air65ReportTransport)?
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
        let expected = try mainState(for: behavior)
        do {
            let transport = try acquireTransport()
            return try applyAndVerify(expected, using: transport)
        } catch {
            invalidateTransport()
            throw error
        }
    }

    private func applyAndVerify(
        _ expected: [UInt8],
        using transport: any Air65ReportTransport
    ) throws -> NuPhyIOEvidence {
        let challenge = makeChallenge()
        let key = try startTemporarySession(transport, challenge: challenge)
        let initial = try readLightState(transport, key: key)

        if !mainStateMatches(initial, expected: expected) {
            try exchange(
                transport,
                request: .write(address: 0, payload: expected),
                key: key
            )
            try exchange(
                transport,
                request: .write(address: 1, payload: [expected[1]]),
                key: key
            )
        }

        let verified = try readLightState(transport, key: key)
        guard mainStateMatches(verified, expected: expected) else {
            throw NuPhyIOAdapterError.mainBacklightReadbackMismatch
        }
        let rhythmBefore = Array(initial.suffix(8))
        let rhythmAfter = Array(verified.suffix(8))
        guard rhythmBefore == rhythmAfter else {
            throw NuPhyIOAdapterError.rhythmLightChanged
        }
        return NuPhyIOEvidence(
            protocolReadbackSucceeded: true,
            visualConfirmation: .notRequested,
            mainState: expected,
            rhythmBefore: rhythmBefore,
            rhythmAfter: rhythmAfter
        )
    }

    public func apply(_ behavior: LightingBehavior) throws {
        _ = try applyAndVerify(behavior)
    }

    public func displays(_ behavior: LightingBehavior) throws -> Bool {
        let expected = try mainState(for: behavior)
        do {
            let transport = try acquireTransport()
            let challenge = makeChallenge()
            let key = try startTemporarySession(transport, challenge: challenge)
            let current = try readLightState(transport, key: key)
            return mainStateMatches(current, expected: expected)
        } catch {
            invalidateTransport()
            throw error
        }
    }

    public func invalidateTransport() {
        ownedTransport = nil
        discoveryNeedsReset = true
    }

    private func acquireTransport() throws -> any Air65ReportTransport {
        if let ownedTransport {
            return ownedTransport
        }
        if discoveryNeedsReset {
            discovery.resetDiscoveryState()
            discoveryNeedsReset = false
        }
        let selected = try Air65DeviceSelector.select(from: discovery.discover())
        let transport = try discovery.open(selected)
        ownedTransport = transport
        return transport
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
        key: NuPhySessionKey
    ) throws -> [UInt8] {
        let payload = try exchange(
            transport,
            request: .read(address: 0, length: 17),
            key: key
        )
        guard payload.count == 17 else {
            throw NuPhyIOAdapterError.invalidLightState
        }
        return payload
    }

    @discardableResult
    private func exchange(
        _ transport: any Air65ReportTransport,
        request: NuPhyRequest,
        key: NuPhySessionKey
    ) throws -> [UInt8] {
        try transport.send(request.encoded(using: key))
        let deadline = Date().addingTimeInterval(Self.responseTimeout)
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

    private func mainState(for behavior: LightingBehavior) throws -> [UInt8] {
        switch behavior {
        case .off:
            return [3, 0, 3, 0, 1, 0, 0, 0, 0]
        case .signal(let appearance):
            guard appearance.pattern == .steady else {
                throw NuPhyIOAdapterError.unsupportedPattern
            }
            return [
                3,
                appearance.brightness.percent,
                3,
                0,
                1,
                0,
                appearance.color.red,
                appearance.color.green,
                appearance.color.blue,
            ]
        }
    }

    private func mainStateMatches(_ state: [UInt8], expected: [UInt8]) -> Bool {
        guard state.count >= 9, expected.count == 9 else { return false }
        if expected[1] == 0 {
            return state[1] == 0
        }
        return Array(state.prefix(9)) == expected
    }

    private static func randomChallenge() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<NuPhyProtocol.payloadLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
