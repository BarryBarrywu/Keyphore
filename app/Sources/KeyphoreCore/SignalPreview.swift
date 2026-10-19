import Darwin
import Foundation

public enum SignalPreviewPhase: String, Codable, Equatable, Sendable {
    case pending
    case presenting
    case completed
    case awaitingVisualConfirmation
    case confirmed
    case rejected
    case failed
}

public struct SignalPreviewRecord: Codable, Equatable, Sendable {
    public let id: String
    public let requestedAt: StatusTimestamp
    public let requestedPreset: LightingPreset?
    public let targetModel: SupportedKeyboardModel?
    public var phase: SignalPreviewPhase
    public var currentPreset: LightingPreset?
    public var stageStartedAt: StatusTimestamp?
    public var presentationIsLit: Bool
    public var completedPresets: [LightingPreset]
    public var protocolReadbackSucceeded: Bool
    public var unmanagedZonesPreserved: Bool
    public var unmanagedZoneProtection: UnmanagedZoneProtection = .readback
    public var visualConfirmation: VisualConfirmation
}

public enum SignalPreviewStoreError: Error, Equatable, Sendable {
    case visualConfirmationUnavailable
    case lockUnavailable
    case lockTimedOut
}

public final class SignalPreviewStore: @unchecked Sendable {
    public let url: URL
    public var lockURL: URL { url.deletingPathExtension().appendingPathExtension("lock") }

    public init(url: URL) {
        self.url = url
    }

    @discardableResult
    public func begin(preset: LightingPreset? = nil, targetModel: SupportedKeyboardModel? = nil,
                      at timestamp: StatusTimestamp = .now) throws -> SignalPreviewRecord {
        let record = SignalPreviewRecord(
            id: UUID().uuidString,
            requestedAt: timestamp,
            requestedPreset: preset,
            targetModel: targetModel,
            phase: .pending,
            currentPreset: nil,
            stageStartedAt: nil,
            presentationIsLit: false,
            completedPresets: [],
            protocolReadbackSucceeded: false,
            unmanagedZonesPreserved: false,
            visualConfirmation: .notRequested
        )
        try withLock { try write(record) }
        return record
    }

    public func load() throws -> SignalPreviewRecord? {
        do {
            return try JSONDecoder().decode(SignalPreviewRecord.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    /// Only the request currently stored may advance; a replaced or removed request cannot return.
    @discardableResult
    public func save(_ record: SignalPreviewRecord) throws -> Bool {
        try withLock {
            guard try load()?.id == record.id else { return false }
            try write(record)
            return true
        }
    }

    private func write(_ record: SignalPreviewRecord) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    public func recordVisualConfirmation(_ confirmation: VisualConfirmation) throws {
        try withLock {
            guard var record = try load(), record.requestedPreset == nil,
                  record.phase == .awaitingVisualConfirmation else {
                throw SignalPreviewStoreError.visualConfirmationUnavailable
            }
            record.visualConfirmation = confirmation
            switch confirmation {
            case .confirmed: record.phase = .confirmed
            case .rejected: record.phase = .rejected
            case .notRequested: record.phase = .awaitingVisualConfirmation
            }
            try write(record)
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SignalPreviewStoreError.lockUnavailable }
        defer { close(descriptor) }
        let started = ContinuousClock.now
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw SignalPreviewStoreError.lockUnavailable }
            guard started.duration(to: .now) < .milliseconds(100) else { throw SignalPreviewStoreError.lockTimedOut }
            usleep(1_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

public protocol CompanionLightingEvidenceApplying: CompanionLightingApplying {
    func applyAndVerify(_ behavior: LightingBehavior) throws -> NuPhyIOEvidence
}

public enum SignalPreviewPollResult: Equatable, Sendable {
    case inactive
    case active
    case finished
    case superseded
    case waitingForTarget
}

public final class SignalPreviewController {
    private static let presetOrder: [LightingPreset] = [.execution, .attention, .completion]
    private let store: SignalPreviewStore
    private let lighting: any CompanionLightingEvidenceApplying
    private let clock: () -> ContinuousClock.Instant
    private var lastPreviewID: String?
    private var lastBehavior: LightingBehavior?
    private var lastVerifiedAt: StatusTimestamp?

    public init(store: SignalPreviewStore, lighting: any CompanionLightingEvidenceApplying,
                clock: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.store = store
        self.lighting = lighting
        self.clock = clock
    }

    public func poll(at now: StatusTimestamp = .now, profile: LocalProfile,
                     targetModel: SupportedKeyboardModel? = nil,
                     selectionStore: KeyboardSelectionStore? = nil) throws -> SignalPreviewPollResult {
        guard var record = try? store.load() else { return .inactive }
        if record.phase == .pending || record.phase == .presenting, let targetModel,
           record.targetModel != targetModel {
            lastPreviewID = nil
            lastBehavior = nil
            lastVerifiedAt = nil
            // Only a still-requested future target may wait. An abandoned target must not
            // hold the current keyboard's live signal indefinitely.
            guard record.targetModel != nil, let selectionStore else { return try fail(&record) }
            guard try selectionStore.load() == record.targetModel else { return try fail(&record) }
            if record.phase == .presenting {
                record.phase = .pending
                record.currentPreset = nil
                record.stageStartedAt = nil
                record.presentationIsLit = false
                record.completedPresets = []
                record.protocolReadbackSucceeded = false
                record.unmanagedZonesPreserved = false
                guard try store.save(record) else { return .superseded }
            }
            return .waitingForTarget
        }
        do {
            switch record.phase {
            case .pending:
                return try present(record.requestedPreset ?? .execution, record: &record, profile: profile, at: now)
            case .presenting:
                return try advance(record: &record, profile: profile, at: now)
            case .completed, .awaitingVisualConfirmation, .confirmed, .rejected, .failed:
                return .inactive
            }
        } catch { return try fail(&record) }
    }

    public func hasActivePreview() throws -> Bool {
        activeRequestID() != nil
    }

    public func activeRequestID() -> String? {
        guard let record = try? store.load(), record.phase == .pending || record.phase == .presenting else { return nil }
        return record.id
    }

    public func cancel(requestID: String? = nil, ownedBy targetModel: SupportedKeyboardModel? = nil) throws {
        guard var record = try store.load(), record.phase == .pending || record.phase == .presenting else { return }
        guard requestID == nil || requestID == record.id else { return }
        if let targetModel, let requested = record.targetModel, requested != targetModel { return }
        _ = try fail(&record)
    }

    private func advance(record: inout SignalPreviewRecord, profile: LocalProfile, at now: StatusTimestamp) throws -> SignalPreviewPollResult {
        guard let signal = record.currentPreset, let started = record.stageStartedAt else { return try fail(&record) }
        let behavior = LightingBehavior.signal(profile.appearance(forPreset: signal), controlledZones: profile.controlledZones)
        if lastPreviewID != record.id || lastBehavior != behavior {
            return try present(signal, record: &record, profile: profile, at: now)
        }
        let dynamic = [behavior.backlight, behavior.strip].contains {
            guard case .signal(let appearance) = $0, appearance.brightness.percent > 0, !appearance.effect.isOff else { return false }
            return ![NativeLightingEffect.backlightStatic, .backlightGradient, .stripStatic].contains(appearance.effect)
        }
        let hold: UInt64 = record.requestedPreset != nil || dynamic ? 6_000 : 2_000
        let elapsed = now >= started ? now.millisecondsSince1970 - started.millisecondsSince1970 : 0
        if elapsed < hold {
            if let verified = lastVerifiedAt, now >= verified,
               now.millisecondsSince1970 - verified.millisecondsSince1970 >= 1_000 {
                if let verifier = lighting as? any CompanionLightingVerifying {
                    guard try verifier.displays(behavior) else { return try fail(&record) }
                } else {
                    let evidence = try lighting.applyAndVerify(behavior)
                    guard evidence.protocolReadbackSucceeded, evidence.unmanagedZonesPreserved else { return try fail(&record) }
                }
                lastVerifiedAt = now
            }
            return .active
        }
        if !record.completedPresets.contains(signal) { record.completedPresets.append(signal) }
        if record.requestedPreset == nil, let index = Self.presetOrder.firstIndex(of: signal),
           index + 1 < Self.presetOrder.count {
            return try present(Self.presetOrder[index + 1], record: &record, profile: profile, at: now)
        }
        record.phase = record.requestedPreset == nil ? .awaitingVisualConfirmation : .completed
        record.currentPreset = nil
        record.stageStartedAt = nil
        record.presentationIsLit = false
        return try store.save(record) ? .finished : .superseded
    }

    private func present(_ signal: LightingPreset, record: inout SignalPreviewRecord, profile: LocalProfile,
                         at now: StatusTimestamp) throws -> SignalPreviewPollResult {
        let behavior = LightingBehavior.signal(profile.appearance(forPreset: signal), controlledZones: profile.controlledZones)
        let started = clock()
        let evidence = try lighting.applyAndVerify(behavior)
        guard evidence.protocolReadbackSucceeded, evidence.unmanagedZonesPreserved else { return try fail(&record) }
        record.phase = .presenting
        record.currentPreset = signal
        record.stageStartedAt = now.adding(started.duration(to: clock()))
        record.presentationIsLit = !behavior.isOff
        record.protocolReadbackSucceeded = true
        record.unmanagedZonesPreserved = true
        if evidence.unmanagedZoneProtection == .untouchedProtocolChannel {
            record.unmanagedZoneProtection = .untouchedProtocolChannel
        }
        lastPreviewID = record.id
        lastBehavior = behavior
        lastVerifiedAt = record.stageStartedAt
        return try store.save(record) ? .active : .superseded
    }

    private func fail(_ record: inout SignalPreviewRecord) throws -> SignalPreviewPollResult {
        record.phase = .failed
        record.protocolReadbackSucceeded = false
        record.unmanagedZonesPreserved = false
        return try store.save(record) ? .finished : .superseded
    }
}
