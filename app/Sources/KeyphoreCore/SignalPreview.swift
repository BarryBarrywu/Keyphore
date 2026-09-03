import Foundation

public enum SignalPreviewPhase: String, Codable, Equatable, Sendable {
    case pending
    case presenting
    case awaitingVisualConfirmation
    case confirmed
    case rejected
    case failed
}

public struct SignalPreviewRecord: Codable, Equatable, Sendable {
    public let id: String
    public let requestedAt: StatusTimestamp
    public var phase: SignalPreviewPhase
    public var currentSignal: CodexSignal?
    public var stageStartedAt: StatusTimestamp?
    public var presentationStep: Int?
    public var presentationIsLit: Bool
    public var completedSignals: [CodexSignal]
    public var protocolReadbackSucceeded: Bool
    public var rhythmLightPreserved: Bool
    public var visualConfirmation: VisualConfirmation
}

public enum SignalPreviewStoreError: Error, Equatable, Sendable {
    case visualConfirmationUnavailable
}

public final class SignalPreviewStore: @unchecked Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    @discardableResult
    public func begin(at timestamp: StatusTimestamp = .now) throws -> SignalPreviewRecord {
        let record = SignalPreviewRecord(
            id: UUID().uuidString,
            requestedAt: timestamp,
            phase: .pending,
            currentSignal: nil,
            stageStartedAt: nil,
            presentationIsLit: false,
            completedSignals: [],
            protocolReadbackSucceeded: false,
            rhythmLightPreserved: false,
            visualConfirmation: .notRequested
        )
        try save(record)
        return record
    }

    public func load() throws -> SignalPreviewRecord? {
        do {
            return try JSONDecoder().decode(SignalPreviewRecord.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    public func save(_ record: SignalPreviewRecord) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    public func recordVisualConfirmation(_ confirmation: VisualConfirmation) throws {
        guard var record = try load(), record.phase == .awaitingVisualConfirmation else {
            throw SignalPreviewStoreError.visualConfirmationUnavailable
        }
        record.visualConfirmation = confirmation
        switch confirmation {
        case .confirmed:
            record.phase = .confirmed
        case .rejected:
            record.phase = .rejected
        case .notRequested:
            record.phase = .awaitingVisualConfirmation
        }
        try save(record)
    }
}

public protocol CompanionLightingEvidenceApplying: CompanionLightingApplying {
    func applyAndVerify(_ behavior: LightingBehavior) throws -> NuPhyIOEvidence
}

public enum SignalPreviewPollResult: Equatable, Sendable {
    case inactive
    case active
    case finished
}

public final class SignalPreviewController {
    private static let signalOrder: [CodexSignal] = [.execution, .attention, .completion]
    private let store: SignalPreviewStore
    private let profileProvider: () throws -> LocalProfile
    private let lighting: any CompanionLightingEvidenceApplying
    private let clock: () -> ContinuousClock.Instant

    public init(
        store: SignalPreviewStore,
        profileProvider: @escaping () throws -> LocalProfile,
        lighting: any CompanionLightingEvidenceApplying,
        clock: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.store = store
        self.profileProvider = profileProvider
        self.lighting = lighting
        self.clock = clock
    }

    public func poll(at now: StatusTimestamp = .now) throws -> SignalPreviewPollResult {
        let storedRecord: SignalPreviewRecord?
        do {
            storedRecord = try store.load()
        } catch {
            return .inactive
        }
        guard var record = storedRecord else { return .inactive }
        do {
            switch record.phase {
            case .pending:
                return try present(.execution, record: &record, at: now)
            case .presenting:
                return try advance(record: &record, at: now)
            case .awaitingVisualConfirmation, .confirmed, .rejected, .failed:
                return .inactive
            }
        } catch {
            return try fail(&record)
        }
    }

    public func hasActivePreview() throws -> Bool {
        do {
            guard let record = try store.load() else { return false }
            return record.phase == .pending || record.phase == .presenting
        } catch {
            return false
        }
    }

    private func advance(
        record: inout SignalPreviewRecord,
        at now: StatusTimestamp
    ) throws -> SignalPreviewPollResult {
        guard
            let currentSignal = record.currentSignal,
            let stageStartedAt = record.stageStartedAt,
            let index = Self.signalOrder.firstIndex(of: currentSignal)
        else {
            return try fail(&record)
        }
        let elapsed = now.millisecondsSince1970 >= stageStartedAt.millisecondsSince1970
            ? now.millisecondsSince1970 - stageStartedAt.millisecondsSince1970
            : 0
        let appearance = appearance(for: currentSignal, in: try profileProvider())
        let flashes = appearance.isVisible && appearance.pattern == .slowFlashing
        let step = record.presentationStep ?? (record.presentationIsLit ? 0 : 1)
        guard elapsed >= (flashes ? 1_000 : 2_000) else { return .active }
        if flashes, step < 3 {
            record.presentationStep = step + 1
            let behavior: LightingBehavior = record.presentationIsLit
                ? .off : .signal(appearance.replacingPattern(with: .steady))
            return try apply(behavior, signal: currentSignal, record: &record, completing: false, at: now)
        }
        guard index + 1 < Self.signalOrder.count else {
            record.phase = .awaitingVisualConfirmation
            record.currentSignal = nil
            record.stageStartedAt = nil
            record.presentationStep = nil
            record.presentationIsLit = false
            try store.save(record)
            return .finished
        }
        return try present(Self.signalOrder[index + 1], record: &record, at: now)
    }

    private func present(
        _ signal: CodexSignal,
        record: inout SignalPreviewRecord,
        at now: StatusTimestamp
    ) throws -> SignalPreviewPollResult {
        let appearance = appearance(for: signal, in: try profileProvider())
        let behavior: LightingBehavior = appearance.isVisible
            ? .signal(appearance.replacingPattern(with: .steady))
            : .off
        record.phase = .presenting
        record.currentSignal = signal
        record.stageStartedAt = now
        record.presentationStep = 0
        record.presentationIsLit = true
        return try apply(
            behavior,
            signal: signal,
            record: &record,
            completing: true,
            at: now
        )
    }

    private func apply(
        _ behavior: LightingBehavior,
        signal: CodexSignal,
        record: inout SignalPreviewRecord,
        completing: Bool,
        at now: StatusTimestamp
    ) throws -> SignalPreviewPollResult {
        do {
            let started = clock()
            let evidence = try lighting.applyAndVerify(behavior)
            // Preserve the full visible phase after hardware acknowledgement, even when I/O is slow.
            record.stageStartedAt = now.adding(started.duration(to: clock()))
            if record.completedSignals.isEmpty {
                record.protocolReadbackSucceeded = evidence.protocolReadbackSucceeded
                record.rhythmLightPreserved = evidence.rhythmBefore == evidence.rhythmAfter
            } else {
                record.protocolReadbackSucceeded =
                    record.protocolReadbackSucceeded && evidence.protocolReadbackSucceeded
                record.rhythmLightPreserved =
                    record.rhythmLightPreserved && evidence.rhythmBefore == evidence.rhythmAfter
            }
            record.presentationIsLit = behavior != .off
            if completing, !record.completedSignals.contains(signal) {
                record.completedSignals.append(signal)
            }
            try store.save(record)
            return .active
        } catch {
            return try fail(&record)
        }
    }

    private func fail(_ record: inout SignalPreviewRecord) throws -> SignalPreviewPollResult {
        record.phase = .failed
        record.protocolReadbackSucceeded = false
        record.rhythmLightPreserved = false
        try store.save(record)
        return .finished
    }

    private func appearance(for signal: CodexSignal, in profile: LocalProfile) -> SignalAppearance {
        profile.appearance(for: signal)
    }
}
