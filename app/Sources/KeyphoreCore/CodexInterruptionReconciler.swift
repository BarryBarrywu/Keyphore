import Foundation
import SQLite3

public final class CodexInterruptionReconciler {
    private let logURL: URL
    private var nextCheck: StatusTimestamp?

    public init(logURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex/logs_2.sqlite")) {
        self.logURL = logURL
    }

    public func reconcile(store: DurableStatusStore, at now: StatusTimestamp) throws {
        if let nextCheck, now < nextCheck { return }
        nextCheck = now.adding(.seconds(1))
        let owners = try store.load().owners.filter {
            $0.id.product == "codex" && $0.signal != .completion && $0.expiresAt > now
        }
        guard !owners.isEmpty else { return }
        var database: OpaquePointer?
        guard sqlite3_open_v2(logURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 25)
        let query = """
            SELECT 1 FROM logs WHERE thread_id = ?1 AND ts >= ?2
            AND target = 'codex_core::tasks'
            AND instr(feedback_log_body, 'aborting running task task_kind=Regular sub_id="' || ?3 || '"') > 0
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for owner in owners {
            let threadID = owner.id.agentID == "main" ? owner.id.sessionID : owner.id.agentID
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, threadID, -1, transient)
            // A late Hook can refresh an already interrupted turn, so use the polling time.
            let current = now.millisecondsSince1970
            let since = (current >= 3_600_000 ? current - 3_600_000 : 0) / 1_000
            sqlite3_bind_int64(statement, 2, Int64(clamping: since))
            sqlite3_bind_text(statement, 3, owner.turnID, -1, transient)
            if sqlite3_step(statement) == SQLITE_ROW {
                try store.removeInterruptedOwner(owner, lockBudget: .milliseconds(100))
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }
}
