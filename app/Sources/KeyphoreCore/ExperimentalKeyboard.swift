import Foundation

public struct ExperimentalKeyboardIdentity: Codable, Equatable, Hashable, Sendable {
    public let productID: UInt16
    public let product: String
    public let usbRevision: Int
    public let protocolRevision: Int

    // Preserve old records for display, but never treat their USB revision as firmware evidence.
    private enum CodingKeys: String, CodingKey {
        case productID, product, protocolRevision
        case usbRevision = "firmwareVersion"
    }

    public var isEligible: Bool {
        guard let model, let profile = NuPhyLightingProfile.experimental(for: model) else { return false }
        return protocolRevision == profile.revision
    }

    public var model: CandidateKeyboardModel? {
        CandidateKeyboardModel.identify(vendorID: 0x19f5, productID: productID, product: product)
    }

    public init?(_ device: HIDDeviceDescriptor) {
        guard device.vendorID == 0x19f5, device.bus == .usb,
              device.interfaceNumber == 3, device.usagePage == 1, device.usage == 0,
              let version = device.usbRevision,
              let model = CandidateKeyboardModel.identify(vendorID: device.vendorID, productID: device.productID, product: device.product),
              Self.isEligible(model), !device.product.isEmpty else { return nil }
        productID = device.productID
        product = device.product
        usbRevision = version
        protocolRevision = NuPhyLightingProfile.experimental(for: model)!.revision
    }

    public static func isEligible(_ model: CandidateKeyboardModel) -> Bool {
        NuPhyLightingProfile.experimental(for: model) != nil
    }
}

public struct ExperimentalKeyboardRecord: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case available, requested, testing, awaitingConfirmation, enabled, revoking, disabled, failed
    }
    public let identity: ExperimentalKeyboardIdentity
    public var phase: Phase
    public var step: Int = 0
    public var stageStartedAt: StatusTimestamp?
    public var protectedState: [UInt8] = []
    public var signalOffVerified = false
    public var lightingAttempted = false
}

public enum ExperimentalKeyboardError: Error {
    case invalidTransition, incompatibleState, deviceChanged, consentRequired
}

public final class ExperimentalKeyboardStore {
    public let url: URL
    public init(url: URL = KeyphoreRuntimePaths.supportDirectory().appending(path: "experimental-keyboards.json")) {
        self.url = url
    }

    public func records() throws -> [ExperimentalKeyboardRecord] {
        do { return try JSONDecoder().decode([ExperimentalKeyboardRecord].self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return [] }
    }

    public func record(for identity: ExperimentalKeyboardIdentity) throws -> ExperimentalKeyboardRecord? {
        try records().first { $0.identity == identity }
    }

    func replace(_ record: ExperimentalKeyboardRecord, expecting phase: ExperimentalKeyboardRecord.Phase?) throws {
        let lease = try CompanionProcessLease.acquire(url: url.appendingPathExtension("lock"))
        defer { withExtendedLifetime(lease) {} }
        var records = try records()
        let index = records.firstIndex { $0.identity == record.identity }
        guard index.map({ records[$0].phase }) == phase else { throw ExperimentalKeyboardError.invalidTransition }
        if let index { records[index] = record } else { records.append(record) }
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }

    public func requestTrial(_ identity: ExperimentalKeyboardIdentity) throws {
        guard identity.isEligible, var record = try record(for: identity), [.available, .failed, .disabled].contains(record.phase) else {
            throw ExperimentalKeyboardError.invalidTransition
        }
        let previous = record.phase
        record.phase = .requested
        record.step = 0
        record.signalOffVerified = false
        try replace(record, expecting: previous)
    }

    public func confirm(_ identity: ExperimentalKeyboardIdentity) throws {
        guard identity.isEligible, var record = try record(for: identity), record.phase == .awaitingConfirmation,
              record.step == 4, record.signalOffVerified, record.protectedState.count == NuPhyLightingProfile.experimental(for: identity.model!)?.protectedRange.count else {
            throw ExperimentalKeyboardError.invalidTransition
        }
        record.phase = .enabled
        try replace(record, expecting: .awaitingConfirmation)
    }

    public func revoke(_ identity: ExperimentalKeyboardIdentity) throws {
        guard identity.isEligible, var record = try record(for: identity) else { throw ExperimentalKeyboardError.invalidTransition }
        let previous = record.phase
        record.phase = .revoking
        try replace(record, expecting: previous)
    }
}

public protocol ExperimentalKeyboardLighting: AnyObject {
    func experimentalDevice() throws -> HIDDeviceDescriptor?
    func inspectExperimental(_ identity: ExperimentalKeyboardIdentity) throws -> [UInt8]
    func applyExperimental(_ behavior: LightingBehavior, identity: ExperimentalKeyboardIdentity) throws -> NuPhyIOEvidence
    func invalidateTransport()
}

public final class ExperimentalKeyboardController {
    private let store: ExperimentalKeyboardStore
    private let lighting: any ExperimentalKeyboardLighting
    private let healthStore: KeyboardHealthStore?
    private var initialized = false
    private let signalOffAcknowledgement: SignalOffAcknowledgementStore?

    public init(store: ExperimentalKeyboardStore, lighting: any ExperimentalKeyboardLighting, healthStore: KeyboardHealthStore? = nil, signalOffAcknowledgement: SignalOffAcknowledgementStore? = nil) {
        self.store = store
        self.lighting = lighting
        self.healthStore = healthStore
        self.signalOffAcknowledgement = signalOffAcknowledgement
    }

    // True reserves the Companion for the explicitly requested trial instead of live task signals.
    public func poll(at now: StatusTimestamp = .now, quitting: Bool = false) throws -> Bool {
        if !initialized {
            for var record in try store.records() where [.testing, .requested].contains(record.phase) {
                let previous = record.phase
                record.phase = .revoking
                try store.replace(record, expecting: previous)
            }
            initialized = true
        }
        guard let device = try lighting.experimentalDevice(), let identity = ExperimentalKeyboardIdentity(device),
              let profile = identity.model.flatMap(NuPhyLightingProfile.experimental) else { return false }
        guard var record = try store.record(for: identity) else {
            let phase: ExperimentalKeyboardRecord.Phase
            do { lighting.invalidateTransport(); _ = try lighting.inspectExperimental(identity); phase = .available }
            catch { phase = .failed }
            try store.replace(ExperimentalKeyboardRecord(identity: identity, phase: phase), expecting: nil)
            return false
        }
        if quitting, [.testing, .requested, .awaitingConfirmation].contains(record.phase) {
            try store.revoke(identity)
            record = try store.record(for: identity)!
        }
        if record.phase == .enabled { return false }
        if [.available, .failed, .disabled].contains(record.phase) {
            if quitting, !record.lightingAttempted || record.signalOffVerified {
                try signalOffAcknowledgement?.acknowledge()
            }
            return false
        }
        try healthStore?.save(.unverified([UnverifiedKeyboardInterface(device)]), at: now)
        do {
            if record.phase == .revoking {
                _ = try lighting.applyExperimental(.off, identity: identity)
                record.phase = .disabled
                record.signalOffVerified = true
                try store.replace(record, expecting: .revoking)
                lighting.invalidateTransport()
                if quitting { try signalOffAcknowledgement?.acknowledge() }
                return false
            }
            if record.phase == .awaitingConfirmation { return true }
            if record.phase == .requested {
                lighting.invalidateTransport()
                try signalOffAcknowledgement?.clear()
                let state = try lighting.inspectExperimental(identity)
                record.protectedState = Array(state[profile.protectedRange])
                record.phase = .testing
                record.lightingAttempted = true
                record.stageStartedAt = nil
                try store.replace(record, expecting: .requested)
            }
            if let started = record.stageStartedAt,
               now.millisecondsSince1970 - min(now.millisecondsSince1970, started.millisecondsSince1970) < 2_000 { return true }
            guard (0..<4).contains(record.step) else { throw ExperimentalKeyboardError.invalidTransition }
            let colors: [SignalColor] = [SignalColor(red: 0, green: 0, blue: 255), SignalColor(red: 255, green: 132, blue: 0), SignalColor(red: 0, green: 255, blue: 0)]
            let behavior: LightingBehavior = record.step < 3 ? .signal(SignalAppearance(
                isVisible: true, color: colors[record.step], brightness: SignalBrightness(percent: 30)!, pattern: .steady
            )) : .off
            let evidence = try lighting.applyExperimental(behavior, identity: identity)
            guard evidence.protocolReadbackSucceeded, evidence.rhythmBefore == record.protectedState,
                  evidence.rhythmAfter == record.protectedState else { throw ExperimentalKeyboardError.incompatibleState }
            record.step += 1
            record.stageStartedAt = now
            if record.step == 4 {
                record.phase = .awaitingConfirmation
                record.signalOffVerified = true
                lighting.invalidateTransport()
            }
            try store.replace(record, expecting: .testing)
        } catch {
            let off = try? lighting.applyExperimental(.off, identity: identity)
            lighting.invalidateTransport()
            if var current = try store.record(for: identity) {
                let previous = current.phase
                current.phase = previous == .revoking && off?.protocolReadbackSucceeded == true ? .disabled : .failed
                current.signalOffVerified = off?.protocolReadbackSucceeded == true
                try store.replace(current, expecting: previous)
            }
        }
        return true
    }
}
