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

public struct ExecutionOwnerID: Codable, Equatable, Hashable, Sendable {
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

public struct ExecutionOwner: Codable, Equatable, Sendable {
    public let id: ExecutionOwnerID
    public let turnID: String
    public let generation: UInt64
    public let expiresAt: StatusTimestamp

    public init(
        id: ExecutionOwnerID,
        turnID: String,
        generation: UInt64,
        expiresAt: StatusTimestamp
    ) {
        self.id = id
        self.turnID = turnID
        self.generation = generation
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case turnID = "turn_id"
        case generation
        case expiresAt = "expires_at"
    }
}

public struct ExecutionExpiry: Equatable, Sendable {
    public let ownerID: ExecutionOwnerID
    public let generation: UInt64
    public let expiresAt: StatusTimestamp

    public init(ownerID: ExecutionOwnerID, generation: UInt64, expiresAt: StatusTimestamp) {
        self.ownerID = ownerID
        self.generation = generation
        self.expiresAt = expiresAt
    }
}

public struct CurrentOwnerTurn: Codable, Equatable, Sendable {
    public let id: ExecutionOwnerID
    public var currentTurnID: String
    public var previousTurnIDs: [String]

    public init(id: ExecutionOwnerID, currentTurnID: String, previousTurnIDs: [String] = []) {
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
    public var owners: [ExecutionOwner]
    public var currentOwnerTurns: [CurrentOwnerTurn]
    public var generation: UInt64

    public init(
        owners: [ExecutionOwner] = [],
        currentOwnerTurns: [CurrentOwnerTurn] = [],
        generation: UInt64 = 0
    ) {
        self.owners = owners
        self.currentOwnerTurns = currentOwnerTurns
        self.generation = generation
    }

    public var expiries: [ExecutionExpiry] {
        owners.map {
            ExecutionExpiry(ownerID: $0.id, generation: $0.generation, expiresAt: $0.expiresAt)
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

    public func recordExecution(
        ownerID: ExecutionOwnerID,
        turnID: String,
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
                ExecutionOwner(
                    id: ownerID,
                    turnID: turnID,
                    generation: status.generation,
                    expiresAt: expiresAt
                ))
        }
    }

    public func removeOwner(
        _ ownerID: ExecutionOwnerID,
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

    public func expire(_ expiry: ExecutionExpiry, at now: StatusTimestamp, lockBudget: Duration)
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
        let hasExecution = try load().owners.contains { $0.expiresAt > now }
        return hasExecution ? .execution : .signalOff
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
    fileprivate mutating func accepts(turnID: String, for ownerID: ExecutionOwnerID, advancing: Bool)
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

    private let store: DurableStatusStore
    private let lockBudget: Duration

    public init(store: DurableStatusStore, lockBudget: Duration = .milliseconds(100)) {
        self.store = store
        self.lockBudget = lockBudget
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
        let ownerID = ExecutionOwnerID(product: "codex", sessionID: sessionID, agentID: agentID)

        switch record.event {
        case .sessionStart, .sessionEnd:
            try store.removeSession(product: "codex", sessionID: sessionID, lockBudget: lockBudget)
        case .subagentStop, .stop:
            guard let turnID = record.turnID, !turnID.isEmpty else {
                throw GuidedSetupError.invalidHookInput
            }
            try store.removeOwner(ownerID, turnID: turnID, lockBudget: lockBudget)
        case .userPromptSubmit, .postToolUse, .subagentStart:
            guard let turnID = record.turnID, !turnID.isEmpty else {
                throw GuidedSetupError.invalidHookInput
            }
            try store.recordExecution(
                ownerID: ownerID,
                turnID: turnID,
                expiresAt: receivedAt.adding(Self.executionLifetime),
                replacingSession: record.event == .userPromptSubmit,
                lockBudget: lockBudget
            )
        case .permissionRequest:
            throw GuidedSetupError.invalidHookInput
        }
    }
}

public protocol CompanionLightingApplying: AnyObject {
    func apply(_ behavior: LightingBehavior) throws
}

public final class KeyphoreCompanion {
    private let store: DurableStatusStore
    private let profile: LocalProfile
    private let lighting: any CompanionLightingApplying
    private let lockBudget: Duration
    private var applied: LightingBehavior?

    public init(
        store: DurableStatusStore,
        profile: LocalProfile,
        lighting: any CompanionLightingApplying,
        lockBudget: Duration = .milliseconds(100)
    ) {
        self.store = store
        self.profile = profile
        self.lighting = lighting
        self.lockBudget = lockBudget
    }

    public func sync(at now: StatusTimestamp = .now) throws {
        for expiry in try store.load().expiries where expiry.expiresAt <= now {
            try store.expire(expiry, at: now, lockBudget: lockBudget)
        }
        let behavior: LightingBehavior =
            try store.outcome(at: now) == .execution
            ? .signal(profile.execution)
            : .off
        guard behavior != applied else { return }
        try lighting.apply(behavior)
        applied = behavior
    }

    public func handle(expiry: ExecutionExpiry, at now: StatusTimestamp) throws {
        try store.expire(expiry, at: now, lockBudget: lockBudget)
        try sync(at: now)
    }
}
