import Darwin
import Foundation

public enum KeyphoreRuntimePaths {
    public static func supportDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appending(path: "Library/Application Support/Keyphore")
    }

    public static func durableStatusURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        supportDirectory(homeDirectory: homeDirectory).appending(path: "status.json")
    }

    public static func keyboardHealthURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        supportDirectory(homeDirectory: homeDirectory).appending(path: "keyboard-health.json")
    }

    public static func localProfileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        supportDirectory(homeDirectory: homeDirectory).appending(path: "profile.json")
    }

    public static func signalPreviewURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        supportDirectory(homeDirectory: homeDirectory).appending(path: "signal-preview.json")
    }
}

public struct StatusTimestamp: Codable, Comparable, Equatable, Sendable {
    public let millisecondsSince1970: UInt64

    public init(millisecondsSince1970: UInt64) {
        self.millisecondsSince1970 = millisecondsSince1970
    }

    public static func milliseconds(_ value: UInt64) -> StatusTimestamp {
        StatusTimestamp(millisecondsSince1970: value)
    }

    public static var now: StatusTimestamp {
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        return StatusTimestamp(millisecondsSince1970: UInt64(max(0, milliseconds)))
    }

    public func adding(_ duration: Duration) -> StatusTimestamp {
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        let milliseconds =
            UInt64(max(0, seconds)) * 1_000
            + UInt64(max(0, attoseconds / 1_000_000_000_000_000))
        let addition = millisecondsSince1970.addingReportingOverflow(milliseconds)
        return .milliseconds(addition.overflow ? UInt64.max : addition.partialValue)
    }

    public static func < (lhs: StatusTimestamp, rhs: StatusTimestamp) -> Bool {
        lhs.millisecondsSince1970 < rhs.millisecondsSince1970
    }
}

public struct SignalOwnerID: Codable, Equatable, Hashable, Sendable {
    public let product: String
    public let sessionID: String
    public let agentID: String

    public init(product: String, sessionID: String, agentID: String) {
        self.product = product
        self.sessionID = sessionID
        self.agentID = agentID
    }

    private enum CodingKeys: String, CodingKey {
        case product
        case sessionID = "session_id"
        case agentID = "agent_id"
    }
}

public struct SignalOwner: Codable, Equatable, Sendable {
    public let id: SignalOwnerID
    public let turnID: String
    public let signal: CodexSignal
    public let generation: UInt64
    public let expiresAt: StatusTimestamp

    public init(
        id: SignalOwnerID,
        turnID: String,
        signal: CodexSignal,
        generation: UInt64,
        expiresAt: StatusTimestamp
    ) {
        self.id = id
        self.turnID = turnID
        self.signal = signal
        self.generation = generation
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case turnID = "turn_id"
        case signal
        case generation
        case expiresAt = "expires_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SignalOwnerID.self, forKey: .id)
        turnID = try container.decode(String.self, forKey: .turnID)
        signal = try container.decodeIfPresent(CodexSignal.self, forKey: .signal) ?? .execution
        generation = try container.decode(UInt64.self, forKey: .generation)
        expiresAt = try container.decode(StatusTimestamp.self, forKey: .expiresAt)
    }
}

public struct SignalExpiry: Equatable, Sendable {
    public let ownerID: SignalOwnerID
    public let generation: UInt64
    public let expiresAt: StatusTimestamp

    public init(ownerID: SignalOwnerID, generation: UInt64, expiresAt: StatusTimestamp) {
        self.ownerID = ownerID
        self.generation = generation
        self.expiresAt = expiresAt
    }
}

public struct CurrentOwnerTurn: Codable, Equatable, Sendable {
    public let id: SignalOwnerID
    public var currentTurnID: String
    public var previousTurnIDs: [String]

    public init(id: SignalOwnerID, currentTurnID: String, previousTurnIDs: [String] = []) {
        self.id = id
        self.currentTurnID = currentTurnID
        self.previousTurnIDs = previousTurnIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case currentTurnID = "current_turn_id"
        case previousTurnIDs = "previous_turn_ids"
    }
}

public struct DurableStatus: Codable, Equatable, Sendable {
    public var owners: [SignalOwner]
    public var currentOwnerTurns: [CurrentOwnerTurn]
    public var generation: UInt64

    public init(
        owners: [SignalOwner] = [],
        currentOwnerTurns: [CurrentOwnerTurn] = [],
        generation: UInt64 = 0
    ) {
        self.owners = owners
        self.currentOwnerTurns = currentOwnerTurns
        self.generation = generation
    }

    public var expiries: [SignalExpiry] {
        owners.map {
            SignalExpiry(ownerID: $0.id, generation: $0.generation, expiresAt: $0.expiresAt)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case owners
        case currentOwnerTurns = "current_owner_turns"
        case generation
    }
}

public enum DurableStatusStoreError: Error, Equatable, Sendable {
    case lockUnavailable
    case lockTimedOut
}

public final class DurableStatusStore: @unchecked Sendable {
    public let url: URL
    public var lockURL: URL { url.deletingPathExtension().appendingPathExtension("lock") }

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> DurableStatus {
        do {
            return try JSONDecoder().decode(DurableStatus.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return DurableStatus()
        }
    }

    public func recordSignal(
        ownerID: SignalOwnerID,
        turnID: String,
        signal: CodexSignal,
        expiresAt: StatusTimestamp,
        replacingSession: Bool,
        lockBudget: Duration
    ) throws {
        try update(lockBudget: lockBudget) { status in
            guard status.accepts(turnID: turnID, for: ownerID, advancing: replacingSession) else {
                return
            }
            status.generation =
                status.generation == UInt64.max
                ? UInt64.max
                : status.generation + 1
            if replacingSession {
                status.owners.removeAll {
                    $0.id.product == ownerID.product && $0.id.sessionID == ownerID.sessionID
                }
            } else {
                status.owners.removeAll { $0.id == ownerID }
            }
            status.owners.append(
                SignalOwner(
                    id: ownerID,
                    turnID: turnID,
                    signal: signal,
                    generation: status.generation,
                    expiresAt: expiresAt
                ))
        }
    }

    public func removeOwner(
        _ ownerID: SignalOwnerID,
        turnID: String,
        lockBudget: Duration
    ) throws {
        try update(lockBudget: lockBudget) { status in
            guard status.accepts(turnID: turnID, for: ownerID, advancing: false) else { return }
            status.owners.removeAll { $0.id == ownerID }
        }
    }

    public func removeSession(product: String, sessionID: String, lockBudget: Duration) throws {
        try update(lockBudget: lockBudget) { status in
            status.owners.removeAll {
                $0.id.product == product && $0.id.sessionID == sessionID
            }
            status.currentOwnerTurns.removeAll {
                $0.id.product == product && $0.id.sessionID == sessionID
            }
        }
    }

    public func reset(lockBudget: Duration) throws {
        try update(lockBudget: lockBudget) { status in
            status = DurableStatus()
        }
    }

    public func expire(_ expiry: SignalExpiry, at now: StatusTimestamp, lockBudget: Duration)
        throws
    {
        try update(lockBudget: lockBudget) { status in
            status.owners.removeAll {
                $0.id == expiry.ownerID
                    && $0.generation == expiry.generation
                    && $0.expiresAt == expiry.expiresAt
                    && $0.expiresAt <= now
            }
        }
    }

    public func outcome(at now: StatusTimestamp) throws -> DurableStatusOutcome {
        let activeSignals = Set(
            try load().owners.lazy
                .filter { $0.expiresAt > now }
                .map(\.signal)
        )
        return .active(activeSignals)
    }

    private func update(
        lockBudget: Duration,
        change: (inout DurableStatus) throws -> Void
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DurableStatusStoreError.lockUnavailable }
        defer { close(descriptor) }
        try acquireLock(descriptor, budget: lockBudget)
        defer { flock(descriptor, LOCK_UN) }

        var status = try load()
        try change(&status)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(status).write(to: url, options: .atomic)
    }

    private func acquireLock(_ descriptor: Int32, budget: Duration) throws {
        let started = ContinuousClock.now
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw DurableStatusStoreError.lockUnavailable
            }
            guard started.duration(to: .now) < budget else {
                throw DurableStatusStoreError.lockTimedOut
            }
            usleep(1_000)
        }
    }
}

extension DurableStatus {
    fileprivate mutating func accepts(turnID: String, for ownerID: SignalOwnerID, advancing: Bool)
        -> Bool
    {
        guard let index = currentOwnerTurns.firstIndex(where: { $0.id == ownerID }) else {
            currentOwnerTurns.append(CurrentOwnerTurn(id: ownerID, currentTurnID: turnID))
            return true
        }
        if currentOwnerTurns[index].currentTurnID == turnID {
            return true
        }
        if !advancing || currentOwnerTurns[index].previousTurnIDs.contains(turnID) {
            return false
        }
        currentOwnerTurns[index].previousTurnIDs.append(currentOwnerTurns[index].currentTurnID)
        currentOwnerTurns[index].currentTurnID = turnID
        return true
    }
}

public final class ProductionHookHandler: @unchecked Sendable {
    public static let executionLifetime = Duration.seconds(60 * 60)
    public static let attentionLifetime = Duration.seconds(60 * 60)

    private let store: DurableStatusStore
    private let lockBudget: Duration
    private let profileProvider: () throws -> LocalProfile

    public convenience init(
        store: DurableStatusStore,
        lockBudget: Duration = .milliseconds(100),
        profile: LocalProfile = .default
    ) {
        self.init(
            store: store,
            lockBudget: lockBudget,
            profileProvider: { profile }
        )
    }

    public init(
        store: DurableStatusStore,
        lockBudget: Duration = .milliseconds(100),
        profileProvider: @escaping () throws -> LocalProfile
    ) {
        self.store = store
        self.lockBudget = lockBudget
        self.profileProvider = profileProvider
    }

    public func handle(_ input: Data, receivedAt: StatusTimestamp = .now) throws {
        let record = try PrivacyAllowedHookRecord(
            jsonData: input,
            receivedAt: String(receivedAt.millisecondsSince1970)
        )
        guard let sessionID = record.sessionID, !sessionID.isEmpty else {
            throw GuidedSetupError.invalidHookInput
        }
        let agentID: String
        switch record.event {
        case .subagentStart, .subagentStop:
            guard let child = record.agentID, !child.isEmpty else {
                throw GuidedSetupError.invalidHookInput
            }
            agentID = child
        case .permissionRequest, .postToolUse:
            agentID = record.agentID.flatMap { $0.isEmpty ? nil : $0 } ?? "main"
        default:
            agentID = "main"
        }
        let ownerID = SignalOwnerID(product: "codex", sessionID: sessionID, agentID: agentID)

        switch record.event {
        case .sessionStart, .sessionEnd:
            try store.removeSession(product: "codex", sessionID: sessionID, lockBudget: lockBudget)
        case .subagentStop:
            guard let turnID = record.turnID, !turnID.isEmpty else {
                throw GuidedSetupError.invalidHookInput
            }
            try store.removeOwner(ownerID, turnID: turnID, lockBudget: lockBudget)
        case .stop:
            guard let turnID = record.turnID, !turnID.isEmpty else {
                throw GuidedSetupError.invalidHookInput
            }
            let profile = try profileProvider()
            try store.recordSignal(
                ownerID: ownerID,
                turnID: turnID,
                signal: .completion,
                expiresAt: receivedAt.adding(
                    .seconds(Int64(profile.completionDisplayDuration.seconds))
                ),
                replacingSession: false,
                lockBudget: lockBudget
            )
        case .userPromptSubmit, .postToolUse, .subagentStart:
            guard let turnID = record.turnID, !turnID.isEmpty else {
                throw GuidedSetupError.invalidHookInput
            }
            try store.recordSignal(
                ownerID: ownerID,
                turnID: turnID,
                signal: .execution,
                expiresAt: receivedAt.adding(Self.executionLifetime),
                replacingSession: record.event == .userPromptSubmit,
                lockBudget: lockBudget
            )
        case .permissionRequest:
            guard let turnID = record.turnID, !turnID.isEmpty else {
                throw GuidedSetupError.invalidHookInput
            }
            try store.recordSignal(
                ownerID: ownerID,
                turnID: turnID,
                signal: .attention,
                expiresAt: receivedAt.adding(Self.attentionLifetime),
                replacingSession: false,
                lockBudget: lockBudget
            )
        }
    }
}

public protocol CompanionLightingApplying: AnyObject {
    func apply(_ behavior: LightingBehavior) throws
}

public protocol CompanionLightingVerifying: AnyObject {
    func displays(_ behavior: LightingBehavior) throws -> Bool
}

public protocol CompanionLightingRecovering: AnyObject {
    func invalidateTransport()
}

public enum CompanionPowerEvent: Equatable, Sendable {
    case willSleep
    case didWake
}

public enum CompanionProcessLeaseError: Error, Equatable, Sendable {
    case alreadyOwned
    case unavailable
}

public final class CompanionProcessLease {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public static func acquire(url: URL) throws -> CompanionProcessLease {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CompanionProcessLeaseError.unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CompanionProcessLeaseError.alreadyOwned
        }
        return CompanionProcessLease(descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public final class CompanionRecoveryController {
    private let companion: KeyphoreCompanion
    private var isAwake = true

    public init(companion: KeyphoreCompanion) {
        self.companion = companion
    }

    public func poll(at now: StatusTimestamp = .now) throws {
        guard isAwake else { return }
        try companion.sync(at: now)
    }

    public func healthCheck(at now: StatusTimestamp = .now) throws {
        guard isAwake else { return }
        try companion.healthCheck(at: now)
    }

    public func handle(
        _ event: CompanionPowerEvent,
        at now: StatusTimestamp = .now
    ) throws {
        isAwake = event == .didWake
        try companion.transportInterrupted(at: now)
    }
}

public final class KeyphoreCompanion {
    private let store: DurableStatusStore
    private let profileProvider: () throws -> LocalProfile
    private let lighting: any CompanionLightingApplying
    private let keyboardHealthStore: KeyboardHealthStore?
    private let lockBudget: Duration
    private let previewController: SignalPreviewController?
    private var applied: LightingBehavior?

    public convenience init(
        store: DurableStatusStore,
        profile: LocalProfile,
        lighting: any CompanionLightingApplying,
        keyboardHealthStore: KeyboardHealthStore? = nil,
        lockBudget: Duration = .milliseconds(100),
        previewStore: SignalPreviewStore? = nil
    ) {
        self.init(
            store: store,
            profileProvider: { profile },
            lighting: lighting,
            keyboardHealthStore: keyboardHealthStore,
            lockBudget: lockBudget,
            previewStore: previewStore
        )
    }

    public init(
        store: DurableStatusStore,
        profileProvider: @escaping () throws -> LocalProfile,
        lighting: any CompanionLightingApplying,
        keyboardHealthStore: KeyboardHealthStore? = nil,
        lockBudget: Duration = .milliseconds(100),
        previewStore: SignalPreviewStore? = nil
    ) {
        self.store = store
        self.profileProvider = profileProvider
        self.lighting = lighting
        self.keyboardHealthStore = keyboardHealthStore
        self.lockBudget = lockBudget
        if let previewStore, let evidenceLighting = lighting as? any CompanionLightingEvidenceApplying {
            previewController = SignalPreviewController(
                store: previewStore,
                profileProvider: profileProvider,
                lighting: evidenceLighting
            )
        } else {
            previewController = nil
        }
    }

    public func sync(at now: StatusTimestamp = .now) throws {
        if let previewController {
            switch try previewController.poll(at: now) {
            case .active:
                applied = nil
                return
            case .finished:
                applied = nil
            case .inactive:
                break
            }
        }
        for expiry in try store.load().expiries where expiry.expiresAt <= now {
            try store.expire(expiry, at: now, lockBudget: lockBudget)
        }
        let outcome = try store.outcome(at: now)
        let profile = try profileProvider()
        let behavior = profile.behavior(for: profile.aggregateSignal(for: outcome), at: now)
        guard behavior != applied else { return }
        do {
            try lighting.apply(behavior)
            applied = behavior
            try keyboardHealthStore?.save(.connected(protocolHealthy: true), at: now)
        } catch {
            applied = nil
            try keyboardHealthStore?.save(Self.health(for: error), at: now)
            throw error
        }
    }

    public func healthCheck(at now: StatusTimestamp = .now) throws {
        if try previewController?.hasActivePreview() == true { return }
        guard let lighting = lighting as? any CompanionLightingVerifying else { return }
        let outcome = try store.outcome(at: now)
        let profile = try profileProvider()
        let behavior = profile.behavior(for: profile.aggregateSignal(for: outcome), at: now)
        do {
            if try lighting.displays(behavior) {
                applied = behavior
                try keyboardHealthStore?.save(.connected(protocolHealthy: true), at: now)
                return
            }
            applied = nil
            try self.lighting.apply(behavior)
            applied = behavior
            try keyboardHealthStore?.save(.connected(protocolHealthy: true), at: now)
        } catch {
            applied = nil
            try keyboardHealthStore?.save(Self.health(for: error), at: now)
            throw error
        }
    }

    public func handle(expiry: SignalExpiry, at now: StatusTimestamp) throws {
        try store.expire(expiry, at: now, lockBudget: lockBudget)
        try sync(at: now)
    }

    public func transportInterrupted(at now: StatusTimestamp = .now) throws {
        applied = nil
        (lighting as? any CompanionLightingRecovering)?.invalidateTransport()
        try keyboardHealthStore?.save(.disconnected, at: now)
    }

    private static func health(for error: Error) -> KeyboardHealth {
        if let selectionError = error as? Air65DeviceSelectionError {
            switch selectionError {
            case .notFound:
                return .disconnected
            case .ambiguous:
                return .ambiguous
            case .unsupported:
                return .connected(protocolHealthy: false)
            }
        }
        if let systemError = error as? SystemAir65HIDError {
            switch systemError {
            case .deviceDisappeared:
                return .disconnected
            case .deviceOpenFailed, .unexpectedReportLength:
                return .connected(protocolHealthy: false)
            case .managerOpenFailed, .reportWriteFailed, .reportReadFailed:
                return .unavailable
            }
        }
        return .connected(protocolHealthy: false)
    }
}
