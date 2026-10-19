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

    public static func keyboardSelectionURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(homeDirectory: homeDirectory).appending(path: "keyboard-selection.json")
    }

    public static func keyboardSelectionSnapshotURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(homeDirectory: homeDirectory).appending(path: "keyboard-selection-snapshot.json")
    }

    public static func keyboardProfilesDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(homeDirectory: homeDirectory).appending(path: "profiles", directoryHint: .isDirectory)
    }

    public static func signalPreviewURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        supportDirectory(homeDirectory: homeDirectory).appending(path: "signal-preview.json")
    }

    public static func quitGateURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        supportDirectory(homeDirectory: homeDirectory).appending(path: "quit-gate")
    }

    public static func configuredStateURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        supportDirectory(homeDirectory: homeDirectory).appending(path: "setup.json")
    }

    public static func signalOffAcknowledgementURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        supportDirectory(homeDirectory: homeDirectory).appending(path: "signal-off-ack")
    }
}

public final class QuitGateStore: @unchecked Sendable {
    public let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public var isActive: Bool {
        fileManager.fileExists(atPath: url.path)
    }

    public func activate() throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url, options: .atomic)
    }

    public func clear() throws {
        guard isActive else { return }
        try fileManager.removeItem(at: url)
    }
}

public final class SignalOffAcknowledgementStore: @unchecked Sendable {
    public let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public var isAcknowledged: Bool {
        fileManager.fileExists(atPath: url.path)
    }

    public func acknowledge() throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url, options: .atomic)
    }

    public func clear() throws {
        guard isAcknowledged else { return }
        try fileManager.removeItem(at: url)
    }
}

public final class LightingOwnershipStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> LightingOwnershipRecord {
        do {
            let record = try JSONDecoder().decode(LightingOwnershipRecord.self, from: Data(contentsOf: url))
            try validate(record)
            return record
        }
        catch CocoaError.fileReadNoSuchFile { return .empty }
    }

    public func save(_ record: LightingOwnershipRecord) throws {
        try validate(record)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    private func validate(_ record: LightingOwnershipRecord) throws {
        try KeyboardSelectionStore.validate(record.model)
        guard record.zones.isEmpty || record.model != nil else { throw KeyboardSelectionFailure.stateUnavailable }
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
    public var isTerminal: Bool
    public var pendingRequestIDs: [String]

    public init(
        id: SignalOwnerID,
        currentTurnID: String,
        previousTurnIDs: [String] = [],
        isTerminal: Bool = false,
        pendingRequestIDs: [String] = []
    ) {
        self.id = id
        self.currentTurnID = currentTurnID
        self.previousTurnIDs = previousTurnIDs
        self.isTerminal = isTerminal
        self.pendingRequestIDs = pendingRequestIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case currentTurnID = "current_turn_id"
        case previousTurnIDs = "previous_turn_ids"
        case isTerminal = "is_terminal"
        case pendingRequestIDs = "pending_request_ids"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SignalOwnerID.self, forKey: .id)
        currentTurnID = try container.decode(String.self, forKey: .currentTurnID)
        previousTurnIDs = try container.decode([String].self, forKey: .previousTurnIDs)
        isTerminal = try container.decodeIfPresent(Bool.self, forKey: .isTerminal) ?? false
        pendingRequestIDs = try container.decodeIfPresent([String].self, forKey: .pendingRequestIDs) ?? []
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
            var status = try JSONDecoder().decode(DurableStatus.self, from: Data(contentsOf: url))
            for owner in status.owners {
                if !status.currentOwnerTurns.contains(where: { $0.id == owner.id }) {
                    status.currentOwnerTurns.append(
                        CurrentOwnerTurn(id: owner.id, currentTurnID: owner.turnID)
                    )
                }
                // Completion owners are terminal evidence in status files written before this flag.
                if owner.signal == .completion {
                    status.markTerminal(turnID: owner.turnID, for: owner.id)
                }
            }
            return status
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
        advancingTurn: Bool = false,
        lockBudget: Duration
    ) throws {
        try update(lockBudget: lockBudget) { status in
            guard status.accepts(
                turnID: turnID,
                for: ownerID,
                advancing: replacingSession || advancingTurn
            ) else {
                return
            }
            status.generation =
                status.generation == UInt64.max
                ? UInt64.max
                : status.generation + 1
            if replacingSession {
                for index in status.currentOwnerTurns.indices
                where status.currentOwnerTurns[index].id.product == ownerID.product
                    && status.currentOwnerTurns[index].id.sessionID == ownerID.sessionID
                    && status.currentOwnerTurns[index].id != ownerID
                {
                    status.currentOwnerTurns[index].isTerminal = true
                }
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
            if signal == .completion {
                status.markTerminal(turnID: turnID, for: ownerID)
            }
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
            status.markTerminal(turnID: turnID, for: ownerID)
        }
    }

    public func removeSession(product: String, sessionID: String, lockBudget: Duration) throws {
        try update(lockBudget: lockBudget) { status in
            status.owners.removeAll {
                $0.id.product == product && $0.id.sessionID == sessionID
            }
            for index in status.currentOwnerTurns.indices
            where status.currentOwnerTurns[index].id.product == product
                && status.currentOwnerTurns[index].id.sessionID == sessionID
            {
                status.currentOwnerTurns[index].isTerminal = true
            }
        }
    }

    public func removeProduct(_ source: AgentSource, lockBudget: Duration) throws {
        try update(lockBudget: lockBudget) { status in
            status.owners.removeAll { $0.id.product == source.rawValue }
            for index in status.currentOwnerTurns.indices
            where status.currentOwnerTurns[index].id.product == source.rawValue {
                status.currentOwnerTurns[index].isTerminal = true
                status.currentOwnerTurns[index].pendingRequestIDs = []
            }
        }
    }

    /// Resolves missing native turn IDs and applies the event in the same cross-process lock.
    public func apply(
        _ event: AgentSignalEvent, at now: StatusTimestamp,
        completionLifetime: Duration, lockBudget: Duration,
        isAuthorized: () -> Bool = { true }
    ) throws {
        try update(lockBudget: lockBudget) { status in
            guard isAuthorized() else { return }
            let ownerID = SignalOwnerID(product: event.source.rawValue,
                                        sessionID: event.sessionID, agentID: event.agentID)
            if event.kind == .sessionStart || event.kind == .sessionEnd {
                let belongs: (SignalOwnerID) -> Bool = {
                    $0.product == ownerID.product && $0.sessionID == ownerID.sessionID
                        && (ownerID.agentID == "main" || $0.agentID == ownerID.agentID)
                }
                status.owners.removeAll { belongs($0.id) }
                for index in status.currentOwnerTurns.indices where belongs(status.currentOwnerTurns[index].id) {
                    status.currentOwnerTurns[index].isTerminal = true
                    status.currentOwnerTurns[index].pendingRequestIDs = []
                }
                return
            }
            let startsTurn = event.kind == .turnStart || event.kind == .agentStart
            let existing = status.currentOwnerTurns.first { $0.id == ownerID }
            let turnID: String
            if startsTurn {
                turnID = event.turnID ?? "local-" + UUID().uuidString
                guard status.accepts(turnID: turnID, for: ownerID, advancing: true) else { return }
            } else {
                // Tool/stop events cannot invent an active turn or revive a finished one.
                guard let existing, event.turnID == nil || event.turnID == existing.currentTurnID else { return }
                turnID = existing.currentTurnID
                if existing.isTerminal {
                    // Grok may cancel after Stop has already fired, so retract that completion.
                    guard event.kind == .turnCancelled else { return }
                }
            }
            guard let index = status.currentOwnerTurns.firstIndex(where: { $0.id == ownerID }) else { return }
            if startsTurn && existing?.currentTurnID != turnID {
                status.currentOwnerTurns[index].pendingRequestIDs = []
            }
            switch event.kind {
            case .turnCancelled, .agentEnd:
                status.owners.removeAll { $0.id == ownerID }
                status.currentOwnerTurns[index].isTerminal = true
                status.currentOwnerTurns[index].pendingRequestIDs = []
                return
            case .attention:
                let requestID = event.requestID ?? "unkeyed"
                if !status.currentOwnerTurns[index].pendingRequestIDs.contains(requestID) {
                    status.currentOwnerTurns[index].pendingRequestIDs.append(requestID)
                }
            case .attentionResolved:
                // Without an ID, correlate only the host's single unkeyed prompt. A named
                // reply must not also clear an independent unkeyed prompt when both exist.
                let resolveUnkeyed = event.requestID == nil
                    || status.currentOwnerTurns[index].pendingRequestIDs == ["unkeyed"]
                status.currentOwnerTurns[index].pendingRequestIDs.removeAll {
                    $0 == event.requestID || (resolveUnkeyed && $0 == "unkeyed")
                }
            case .turnComplete:
                status.currentOwnerTurns[index].isTerminal = true
                status.currentOwnerTurns[index].pendingRequestIDs = []
            default: break
            }
            let signal: CodexSignal = event.kind == .turnComplete ? .completion
                : (status.currentOwnerTurns[index].pendingRequestIDs.isEmpty ? .execution : .attention)
            status.generation = status.generation == UInt64.max ? UInt64.max : status.generation + 1
            status.owners.removeAll { $0.id == ownerID }
            status.owners.append(SignalOwner(
                id: ownerID, turnID: turnID, signal: signal, generation: status.generation,
                expiresAt: now.adding(signal == .completion ? completionLifetime : ProductionHookHandler.executionLifetime)
            ))
        }
    }

    public func removeInterruptedOwner(_ owner: SignalOwner, lockBudget: Duration) throws {
        try update(lockBudget: lockBudget) { status in
            guard status.owners.contains(owner) else { return }
            status.markTerminal(turnID: owner.turnID, for: owner.id)
            status.owners.removeAll { $0 == owner }
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
    fileprivate mutating func markTerminal(turnID: String, for ownerID: SignalOwnerID) {
        if let index = currentOwnerTurns.firstIndex(where: { $0.id == ownerID }) {
            guard currentOwnerTurns[index].currentTurnID == turnID else { return }
            currentOwnerTurns[index].isTerminal = true
        } else {
            currentOwnerTurns.append(
                CurrentOwnerTurn(id: ownerID, currentTurnID: turnID, isTerminal: true)
            )
        }
    }

    fileprivate mutating func accepts(turnID: String, for ownerID: SignalOwnerID, advancing: Bool)
        -> Bool
    {
        guard let index = currentOwnerTurns.firstIndex(where: { $0.id == ownerID }) else {
            currentOwnerTurns.append(CurrentOwnerTurn(id: ownerID, currentTurnID: turnID))
            return true
        }
        if currentOwnerTurns[index].currentTurnID == turnID {
            return !currentOwnerTurns[index].isTerminal
        }
        if !advancing || currentOwnerTurns[index].previousTurnIDs.contains(turnID) {
            return false
        }
        currentOwnerTurns[index].previousTurnIDs.append(currentOwnerTurns[index].currentTurnID)
        currentOwnerTurns[index].currentTurnID = turnID
        currentOwnerTurns[index].isTerminal = false
        return true
    }
}

public final class ProductionHookHandler: @unchecked Sendable {
    public static let executionLifetime = Duration.seconds(60 * 60)
    public static let attentionLifetime = Duration.seconds(60 * 60)

    private let store: DurableStatusStore
    private let quitGate: QuitGateStore?
    private let configuredStateURL: URL?
    private let lockBudget: Duration
    private let completionDurationProvider: () throws -> CompletionDisplayDuration

    public convenience init(
        store: DurableStatusStore,
        lockBudget: Duration = .milliseconds(100),
        quitGate: QuitGateStore? = nil,
        configuredStateURL: URL? = nil,
        profile: LocalProfile = .default
    ) {
        self.init(
            store: store,
            lockBudget: lockBudget,
            quitGate: quitGate,
            configuredStateURL: configuredStateURL,
            completionDurationProvider: { profile.completionDisplayDuration }
        )
    }

    public init(
        store: DurableStatusStore,
        lockBudget: Duration = .milliseconds(100),
        quitGate: QuitGateStore? = nil,
        configuredStateURL: URL? = nil,
        completionDurationProvider: @escaping () throws -> CompletionDisplayDuration
    ) {
        self.store = store
        self.quitGate = quitGate
        self.configuredStateURL = configuredStateURL
        self.lockBudget = lockBudget
        self.completionDurationProvider = completionDurationProvider
    }

    public func handle(_ input: Data, receivedAt: StatusTimestamp = .now) throws {
        guard quitGate?.isActive != true else { return }
        if let configuredStateURL,
           !FileManager.default.fileExists(atPath: configuredStateURL.path)
        {
            return
        }
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
            let duration = try completionDurationProvider()
            try store.recordSignal(
                ownerID: ownerID,
                turnID: turnID,
                signal: .completion,
                expiresAt: receivedAt.adding(
                    .seconds(Int64(duration.seconds))
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
                advancingTurn: record.event == .subagentStart,
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
    private let interruptionReconciler: CodexInterruptionReconciler?
    private let profileProvider: (SupportedKeyboardModel?) throws -> LocalProfile
    private let lighting: any CompanionLightingApplying
    private let keyboardHealthStore: KeyboardHealthStore?
    private let lockBudget: Duration
    private let previewController: SignalPreviewController?
    private let signalOffAcknowledgement: SignalOffAcknowledgementStore?
    private let quitGate: QuitGateStore?
    private var applied: LightingBehavior?
    private let ownershipStore: LightingOwnershipStore?
    private var ownedZones: Set<LightingZone>?
    private var activeModel: SupportedKeyboardModel?
    private let selectionStore: KeyboardSelectionStore?
    private let selectionSnapshotStore: KeyboardSelectionSnapshotStore?
    private var desiredModel: SupportedKeyboardModel?
    private var inventory: [KeyboardInventoryEntry] = []
    private var lastSelectionSnapshot: KeyboardSelectionSnapshot?
    private var lastHealth: KeyboardHealth?
    private var lastHealthSavedAt: StatusTimestamp?

    public convenience init(
        store: DurableStatusStore,
        profile: LocalProfile,
        lighting: any CompanionLightingApplying,
        keyboardHealthStore: KeyboardHealthStore? = nil,
        lockBudget: Duration = .milliseconds(100),
        previewStore: SignalPreviewStore? = nil,
        signalOffAcknowledgement: SignalOffAcknowledgementStore? = nil,
        quitGate: QuitGateStore? = nil,
        ownershipStore: LightingOwnershipStore? = nil,
        selectionStore: KeyboardSelectionStore? = nil,
        selectionSnapshotStore: KeyboardSelectionSnapshotStore? = nil,
        interruptionReconciler: CodexInterruptionReconciler? = nil
    ) {
        self.init(
            store: store,
            profileProvider: { _ in profile },
            lighting: lighting,
            keyboardHealthStore: keyboardHealthStore,
            lockBudget: lockBudget,
            previewStore: previewStore,
            signalOffAcknowledgement: signalOffAcknowledgement,
            quitGate: quitGate,
            ownershipStore: ownershipStore,
            selectionStore: selectionStore,
            selectionSnapshotStore: selectionSnapshotStore,
            interruptionReconciler: interruptionReconciler
        )
    }

    public init(
        store: DurableStatusStore,
        profileProvider: @escaping (SupportedKeyboardModel?) throws -> LocalProfile,
        lighting: any CompanionLightingApplying,
        keyboardHealthStore: KeyboardHealthStore? = nil,
        lockBudget: Duration = .milliseconds(100),
        previewStore: SignalPreviewStore? = nil,
        signalOffAcknowledgement: SignalOffAcknowledgementStore? = nil,
        quitGate: QuitGateStore? = nil,
        ownershipStore: LightingOwnershipStore? = nil,
        selectionStore: KeyboardSelectionStore? = nil,
        selectionSnapshotStore: KeyboardSelectionSnapshotStore? = nil,
        interruptionReconciler: CodexInterruptionReconciler? = nil
    ) {
        self.store = store
        self.interruptionReconciler = interruptionReconciler
        self.profileProvider = profileProvider
        self.lighting = lighting
        self.keyboardHealthStore = keyboardHealthStore
        self.lockBudget = lockBudget
        self.signalOffAcknowledgement = signalOffAcknowledgement
        self.quitGate = quitGate
        self.ownershipStore = ownershipStore
        self.selectionStore = selectionStore
        self.selectionSnapshotStore = selectionSnapshotStore
        if let previewStore, let evidenceLighting = lighting as? any CompanionLightingEvidenceApplying {
            previewController = SignalPreviewController(
                store: previewStore,
                lighting: evidenceLighting
            )
        } else {
            previewController = nil
        }
    }

    public func sync(at now: StatusTimestamp = .now) throws {
        if quitGate?.isActive != true {
            // Status maintenance is independent of hardware and ownership-journal availability.
            try interruptionReconciler?.reconcile(store: store, at: now)
            for expiry in try store.load().expiries where expiry.expiresAt <= now {
                try store.expire(expiry, at: now, lockBudget: lockBudget)
            }
        }
        if ownedZones == nil {
            let inheritedPreview = previewController?.activeRequestID()
            do {
                let record = try ownershipStore?.load() ?? .empty
                try KeyboardSelectionStore.validate(record.model)
                guard selectionStore == nil || record.zones.isEmpty || record.model != nil else {
                    throw KeyboardSelectionFailure.stateUnavailable
                }
                if selectionStore != nil {
                    if let inheritedPreview { try previewController?.cancel(requestID: inheritedPreview) }
                }
                try (lighting as? any CompanionKeyboardSelecting)?.selectTarget(record.model)
                activeModel = record.model
                ownedZones = record.zones
            } catch {
                applied = nil
                try? signalOffAcknowledgement?.clear()
                if let inheritedPreview { try? previewController?.cancel(requestID: inheritedPreview) }
                try? publishSelection(.blocked, failure: .stateUnavailable, at: now)
                try saveHealth(.unavailable, at: now)
                throw error
            }
        }
        if quitGate?.isActive == true {
            // Ownership survives status resets; quit never needs the signal profile.
            try? previewController?.cancel()
            if !ownedZones!.isEmpty {
                try (lighting as? any CompanionKeyboardSelecting)?.selectTarget(activeModel)
                // Another lighting tool may have changed a zone since our cached idle-off frame.
                applied = nil
                try apply(.off(zones: ownedZones!), at: now)
            }
            try ownershipStore?.save(.empty)
            ownedZones = []
            activeModel = nil
            try (lighting as? any CompanionKeyboardSelecting)?.selectTarget(nil)
            try acknowledgeOff()
            return
        }
        let profile: LocalProfile
        let desiredZones: Set<LightingZone>
        let previewRequestID = previewController?.activeRequestID()
        do {
            try updateSelection(at: now, previewRequestID: previewRequestID)
            // Old-target cleanup uses only its journal. Read the new target's settings after
            // the switch completes, so unsupported or corrupt settings on another model cannot leak.
            profile = try profileProvider(activeModel)
            desiredZones = Set(LightingZone.allCases.filter { profile.controlledZones.contains($0) })
            // Check zone ownership before persisting it. Effects are checked when actually applied,
            // after expiry/reconciliation and preview choose this poll's presentation.
            try (lighting as? any CompanionLightingValidating)?.validate(.off(for: profile.controlledZones))
            if activeModel == nil { activeModel = (lighting as? any CompanionKeyboardIdentifying)?.connectedModel }
            try prepareOwnership(desiredZones, at: now)
            if let selectionStore, try selectionStore.load() != desiredModel {
                applied = nil
                try signalOffAcknowledgement?.clear()
                try publishSelection(.pending, at: now)
                return
            }
        } catch {
            applied = nil
            try? signalOffAcknowledgement?.clear()
            if let previewRequestID {
                if selectionStore == nil { try? previewController?.cancel(requestID: previewRequestID) }
                else if let activeModel { try? previewController?.cancel(requestID: previewRequestID, ownedBy: activeModel) }
            }
            try saveHealth(Self.health(for: error), at: now)
            throw error
        }
        if let previewController {
            let result: SignalPreviewPollResult
            do {
                result = try previewController.poll(at: now, profile: profile,
                    targetModel: selectionStore == nil ? nil : activeModel, selectionStore: selectionStore)
            } catch {
                // Preview may have changed the device before its checkpoint failed.
                applied = nil
                try? signalOffAcknowledgement?.clear()
                throw error
            }
            switch result {
            case .superseded, .waitingForTarget:
                applied = nil
                try signalOffAcknowledgement?.clear()
                return
            case .active:
                applied = nil
                try signalOffAcknowledgement?.clear()
                try settleOwnership(desiredZones)
                try saveHealth(.connected(protocolHealthy: true, model: (lighting as? any CompanionKeyboardIdentifying)?.connectedModel), at: now)
                return
            case .finished:
                applied = nil
            case .inactive:
                break
            }
        }
        let outcome = try store.outcome(at: now)
        let signal = profile.aggregateSignal(for: outcome)
        let behavior = profile.behavior(for: signal)
        try apply(behavior, at: now)
        try settleOwnership(desiredZones)
        if behavior.isOff { try acknowledgeOff() }
    }

    private func updateSelection(at now: StatusTimestamp, previewRequestID: String?) throws {
        guard let selectionStore, let selector = lighting as? any CompanionKeyboardSelecting else { return }
        func refreshRequestAndInventory() throws {
            do { desiredModel = try selectionStore.load() }
            catch let failure as KeyboardSelectionFailure { throw failure }
            catch { throw KeyboardSelectionFailure.stateUnavailable }
            inventory = []
            do { inventory = try selector.keyboardInventory() }
            catch { throw KeyboardSelectionFailure.discoveryFailed }
            do {
                // Empty discovery can be transient during startup/wake. A different connected
                // keyboard establishes that an absent manual preference should return to Auto.
                if let desiredModel, inventory.contains(where: { $0.count > 0 }),
                   !inventory.contains(where: { $0.model == desiredModel && $0.count > 0 }) {
                    try selectionStore.clear(ifUnchanged: desiredModel)
                }
                desiredModel = try selectionStore.load()
            } catch let failure as KeyboardSelectionFailure { throw failure }
            catch { throw KeyboardSelectionFailure.stateUnavailable }
        }
        func target() -> (model: SupportedKeyboardModel?, failure: KeyboardSelectionFailure?) {
            if let desiredModel {
                let count = inventory.first { $0.model == desiredModel }?.count ?? 0
                return (desiredModel, count == 1 ? nil : count == 0 ? .notFound : .ambiguous)
            }
            let count = inventory.reduce(0) { $0 + $1.count }
            return count == 1 ? (inventory.first { $0.count > 0 }?.model, nil) : (nil, count == 0 ? .notFound : .ambiguous)
        }
        do {
            try refreshRequestAndInventory()
            var next = target()
            if next.model != activeModel {
                let retryingBlockedRequest = lastSelectionSnapshot.map {
                    $0.phase == .blocked && $0.desiredModel == desiredModel
                        && $0.activeModel == activeModel && $0.inventory == inventory
                } ?? false
                if !retryingBlockedRequest { try publishSelection(.pending, at: now) }
                applied = nil
                try signalOffAcknowledgement?.clear()
                if let previewRequestID, let activeModel {
                    try previewController?.cancel(requestID: previewRequestID, ownedBy: activeModel)
                }
                // A new connected topology relinquishes a vanished control endpoint without
                // sending or claiming a verified off. Empty discovery and quit retain ownership.
                let oldTargetIsAbsent = activeModel.map { model in
                    (inventory.first { $0.model == model }?.count ?? 0) == 0
                } ?? false
                let releaseDisconnectedOwner = inventory.contains { $0.count > 0 } && oldTargetIsAbsent
                if !ownedZones!.isEmpty && !releaseDisconnectedOwner {
                    // Cleanup is pinned to the journal's actual owner, never the new preference.
                    try selector.selectTarget(activeModel)
                    do { try lighting.apply(.off(zones: ownedZones!)) }
                    catch let error as Air65DeviceSelectionError where error == .notFound || error == .ambiguous {
                        throw KeyboardSelectionFailure.oldTargetUnavailable
                    } catch { throw KeyboardSelectionFailure.oldTargetOffFailed }
                }
                // A failed journal clear must leave the old owner recoverable and prevent all new writes.
                try ownershipStore?.save(.empty)
                ownedZones = []
                activeModel = nil
                try selector.selectTarget(nil)
                // The person may change B to C while A's off/readback is in flight.
                try refreshRequestAndInventory()
                next = target()
                try selector.selectTarget(next.model)
                try ownershipStore?.save(LightingOwnershipRecord(model: next.model, zones: []))
                activeModel = next.model
            } else {
                try selector.selectTarget(activeModel)
            }
            if let failure = next.failure { throw failure }
            try publishSelection(.applied, at: now)
        } catch {
            let failure = (error as? KeyboardSelectionFailure) ?? .stateUnavailable
            try? publishSelection(.blocked, failure: failure, at: now)
            throw failure
        }
    }

    private func publishSelection(_ phase: KeyboardSelectionPhase, failure: KeyboardSelectionFailure? = nil,
                                  at now: StatusTimestamp) throws {
        guard let selectionSnapshotStore else { return }
        if let last = lastSelectionSnapshot, last.desiredModel == desiredModel, last.activeModel == activeModel,
           last.inventory == inventory, last.phase == phase, last.failure == failure,
           now >= last.observedAt, now.millisecondsSince1970 - last.observedAt.millisecondsSince1970 < 1_000 { return }
        let snapshot = KeyboardSelectionSnapshot(desiredModel: desiredModel, activeModel: activeModel,
            inventory: inventory, phase: phase, failure: failure, observedAt: now)
        try selectionSnapshotStore.save(snapshot)
        lastSelectionSnapshot = snapshot
    }

    private func prepareOwnership(_ desired: Set<LightingZone>, at now: StatusTimestamp) throws {
        let previous = ownedZones ?? []
        guard previous != desired else { return }
        let combined = previous.union(desired)
        try ownershipStore?.save(LightingOwnershipRecord(model: activeModel, zones: combined))
        ownedZones = combined
        applied = nil
        let released = previous.subtracting(desired)
        guard !released.isEmpty else { return }
        do { try lighting.apply(.off(zones: released)) }
        catch {
            try saveHealth(Self.health(for: error), at: now)
            throw error
        }
    }

    private func settleOwnership(_ desired: Set<LightingZone>) throws {
        guard ownedZones != desired else { return }
        try ownershipStore?.save(LightingOwnershipRecord(model: activeModel, zones: desired))
        ownedZones = desired
    }

    private func apply(_ behavior: LightingBehavior, at now: StatusTimestamp) throws {
        guard behavior != applied else { return }
        if !behavior.isOff {
            try signalOffAcknowledgement?.clear()
        }
        do {
            try lighting.apply(behavior)
            applied = behavior
            try saveHealth(.connected(protocolHealthy: true, model: (lighting as? any CompanionKeyboardIdentifying)?.connectedModel), at: now)
        } catch {
            applied = nil
            try saveHealth(Self.health(for: error), at: now)
            throw error
        }
    }

    public func healthCheck(at now: StatusTimestamp = .now) throws {
        if selectionStore != nil {
            try sync(at: now)
            if quitGate?.isActive == true { return }
        }
        if quitGate?.isActive == true {
            try sync(at: now)
            return
        }
        if try previewController?.hasActivePreview() == true { return }
        guard let lighting = lighting as? any CompanionLightingVerifying else { return }
        let outcome = try store.outcome(at: now)
        let profile = try profileProvider(activeModel)
        let signal = profile.aggregateSignal(for: outcome)
        let desiredZones = Set(LightingZone.allCases.filter { profile.controlledZones.contains($0) })
        guard let behavior = applied, behavior == profile.behavior(for: signal), ownedZones == desiredZones else {
            try sync(at: now)
            return
        }
        do {
            if try lighting.displays(behavior) {
                applied = behavior
                if behavior.isOff, signalOffAcknowledgement?.isAcknowledged == false {
                    try signalOffAcknowledgement?.acknowledge()
                }
                try saveHealth(.connected(protocolHealthy: true, model: (lighting as? any CompanionKeyboardIdentifying)?.connectedModel), at: now)
                return
            }
            applied = nil
            try self.lighting.apply(behavior)
            applied = behavior
            if behavior.isOff, signalOffAcknowledgement?.isAcknowledged == false {
                try signalOffAcknowledgement?.acknowledge()
            }
            try saveHealth(.connected(protocolHealthy: true, model: (lighting as? any CompanionKeyboardIdentifying)?.connectedModel), at: now)
        } catch {
            applied = nil
            try saveHealth(Self.health(for: error), at: now)
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
        try saveHealth(.disconnected, at: now)
    }

    private func acknowledgeOff() throws {
        if signalOffAcknowledgement?.isAcknowledged == false { try signalOffAcknowledgement?.acknowledge() }
    }

    private func saveHealth(_ health: KeyboardHealth, at now: StatusTimestamp) throws {
        if health == lastHealth, let saved = lastHealthSavedAt, now >= saved,
           now.millisecondsSince1970 - saved.millisecondsSince1970 < 1_000 { return }
        try keyboardHealthStore?.save(health, at: now)
        lastHealth = health
        lastHealthSavedAt = now
    }

    private static func health(for error: Error) -> KeyboardHealth {
        if let selection = error as? KeyboardSelectionFailure {
            switch selection {
            case .notFound, .oldTargetUnavailable: return .disconnected
            case .ambiguous: return .ambiguous
            case .oldTargetOffFailed: return .connected(protocolHealthy: false)
            case .unsupportedSelection, .discoveryFailed, .stateUnavailable: return .unavailable
            }
        }
        if let capability = error as? LightingCapabilityError {
            return .connected(protocolHealthy: false, model: capability.model)
        }
        if let selectionError = error as? Air65DeviceSelectionError {
            switch selectionError {
            case .unverified(let interfaces):
                return .unverified(interfaces)
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
