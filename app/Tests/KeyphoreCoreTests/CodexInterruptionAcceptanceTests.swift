import Foundation
import KeyphoreCore
import SQLite3
import XCTest

final class CodexInterruptionAcceptanceTests: XCTestCase {
    func testCapturedInterruptedTurnStopsContributingExecution() throws {
        let fixture = try InterruptionFixture()
        try fixture.start()
        try fixture.abort()

        let lighting = InterruptionLighting()
        let companion = KeyphoreCompanion(store: fixture.store, profile: .default,
                                         lighting: lighting, interruptionReconciler: fixture.reconciler)
        try companion.sync(at: .milliseconds(2_000))

        XCTAssertEqual(try fixture.store.outcome(at: .milliseconds(2_000)), .active([]),
                       "Interrupted Codex turn must not keep Task in Progress active")
        XCTAssertEqual(lighting.behaviors, [.off])
    }

    func testSnapshotRemovalDoesNotEraseRenewedOwner() throws {
        let fixture = try InterruptionFixture()
        try fixture.start()
        let old = try XCTUnwrap(fixture.store.load().owners.first)
        try fixture.start(turn: "new-turn")
        try fixture.store.removeInterruptedOwner(old, lockBudget: .milliseconds(100))
        XCTAssertEqual(try fixture.store.load().owners.map(\.turnID), ["new-turn"])
    }

    func testLateToolHookDoesNotResurrectInterruptedTurn() throws {
        let fixture = try InterruptionFixture()
        try fixture.start()
        try fixture.abort()
        try fixture.reconcile()
        try ProductionHookHandler(store: fixture.store).handle(
            Data(#"{"hook_event_name":"PostToolUse","session_id":"session","turn_id":"turn"}"#.utf8),
            receivedAt: .milliseconds(10_000))
        try fixture.reconcile(at: 11_000)
        XCTAssertTrue(try fixture.store.load().owners.isEmpty)
    }

    func testInterruptedChildPreservesMainOwner() throws {
        let fixture = try InterruptionFixture()
        try fixture.start()
        try ProductionHookHandler(store: fixture.store).handle(
            Data(#"{"hook_event_name":"SubagentStart","session_id":"session","agent_id":"child","turn_id":"child-turn"}"#.utf8),
            receivedAt: .milliseconds(1_000))
        try fixture.abort(session: "child", turn: "child-turn")
        try fixture.reconcile()
        XCTAssertEqual(try fixture.store.load().owners.map(\.id.agentID), ["main"])
    }

    func testOtherTurnAndOtherSessionDoNotClearExecution() throws {
        let fixture = try InterruptionFixture()
        try fixture.start()
        try fixture.abort(turn: "old-turn")
        try fixture.abort(session: "other-session")
        try fixture.reconcile()
        XCTAssertEqual(try fixture.store.load().owners.map(\.signal), [.execution])
    }

    func testLongTaskWithoutInterruptionKeepsExecution() throws {
        let fixture = try InterruptionFixture()
        try fixture.start()
        try fixture.reconcile(at: 3_000_000)
        XCTAssertEqual(try fixture.store.load().owners.map(\.signal), [.execution])
    }

    func testInterruptionPreservesParallelSession() throws {
        let fixture = try InterruptionFixture()
        try fixture.start()
        try fixture.start(session: "parallel")
        try fixture.abort()
        try fixture.reconcile()
        XCTAssertEqual(try fixture.store.load().owners.map(\.id.sessionID), ["parallel"])
    }

    func testUnreadableOrChangedDatabaseDoesNotClearExecution() throws {
        let fixture = try InterruptionFixture()
        try fixture.start()
        try fixture.execute("DROP TABLE logs")
        try fixture.reconcile()
        XCTAssertEqual(try fixture.store.load().owners.map(\.signal), [.execution])
        try FileManager.default.removeItem(at: fixture.logURL)
        try fixture.reconcile(at: 4_000)
        XCTAssertEqual(try fixture.store.load().owners.map(\.signal), [.execution])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.logURL.path))
    }
}

private final class InterruptionLighting: CompanionLightingApplying {
    var behaviors: [LightingBehavior] = []
    func apply(_ behavior: LightingBehavior) throws { behaviors.append(behavior) }
}

private final class InterruptionFixture {
    let directory: URL
    let logURL: URL
    let store: DurableStatusStore
    lazy var reconciler = CodexInterruptionReconciler(logURL: logURL)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appending(path: "logs.sqlite")
        store = DurableStatusStore(url: directory.appending(path: "status.json"))
        try execute("CREATE TABLE logs(thread_id TEXT, ts INTEGER, target TEXT, feedback_log_body TEXT)")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func execute(_ sql: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(logURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    func start(session: String = "session", turn: String = "turn") throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": session, "turn_id": turn,
        ])
        try ProductionHookHandler(store: store).handle(data, receivedAt: .milliseconds(1_000))
    }

    func abort(session: String = "session", turn: String = "turn") throws {
        try execute("""
            INSERT INTO logs VALUES ('\(session)', 2, 'codex_core::tasks',
            'session_loop{thread_id=\(session)}:submission_dispatch{otel.name="op.dispatch.interrupt"}: aborting running task task_kind=Regular sub_id="\(turn)"')
            """)
    }

    func reconcile(at milliseconds: UInt64 = 2_000) throws {
        try reconciler.reconcile(store: store, at: .milliseconds(milliseconds))
    }
}
