import Darwin
import Foundation
import KeyphoreCore
import XCTest

final class ExecutionFlowAcceptanceTests: XCTestCase {
    func testProductionHookPersistsPrivateSafeExecutionAndCompanionAppliesDefaultBlue() throws {
        let fixture = try ExecutionFixture()
        let privateValues = [
            "private prompt text",
            "private assistant prose",
            "/private/transcript.jsonl",
            "private tool output",
        ]
        let input: [String: Any] = [
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-7",
            "turn_id": "turn-3",
            "prompt": privateValues[0],
            "last_assistant_message": privateValues[1],
            "transcript_path": privateValues[2],
            "tool_output": privateValues[3],
        ]

        try fixture.hook.handle(
            JSONSerialization.data(withJSONObject: input),
            receivedAt: .milliseconds(0)
        )

        let persisted = try String(contentsOf: fixture.statusURL, encoding: .utf8)
        for privateValue in privateValues {
            XCTAssertFalse(persisted.contains(privateValue))
        }
        XCTAssertEqual(
            try fixture.store.load().owners.map(\.id),
            [
                ExecutionOwnerID(product: "codex", sessionID: "session-7", agentID: "main")
            ])

        try fixture.companion.sync(at: .milliseconds(0))

        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.execution)])
    }

    func testSubagentEndingLeavesMainExecutionOwnerActive() throws {
        let fixture = try ExecutionFixture()
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "main-turn", at: 0)
        try fixture.handle(
            "SubagentStart",
            session: "session-1",
            agent: "agent-1",
            turn: "child-turn",
            at: 10
        )
        try fixture.handle(
            "SubagentStop",
            session: "session-1",
            agent: "agent-1",
            turn: "child-turn",
            at: 20
        )

        let status = try fixture.store.load()
        XCTAssertEqual(status.owners.map(\.id.agentID), ["main"])

        try fixture.companion.sync(at: .milliseconds(20))
        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.execution)])
    }

    func testMainOwnerEndingCannotClearAnotherActiveSession() throws {
        let fixture = try ExecutionFixture()
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-1", at: 0)
        try fixture.handle("UserPromptSubmit", session: "session-2", turn: "turn-1", at: 10)
        try fixture.handle("Stop", session: "session-1", turn: "turn-1", at: 20)

        let status = try fixture.store.load()
        XCTAssertEqual(status.owners.map(\.id.sessionID), ["session-2"])
    }

    func testMainOwnerEndingLeavesChildExecutionInTheSameSession() throws {
        let fixture = try ExecutionFixture()
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "main-turn", at: 0)
        try fixture.handle(
            "SubagentStart",
            session: "session-1",
            agent: "agent-1",
            turn: "child-turn",
            at: 10
        )

        try fixture.handle("Stop", session: "session-1", turn: "main-turn", at: 20)

        let status = try fixture.store.load()
        XCTAssertEqual(status.owners.map(\.id.agentID), ["agent-1"])
        try fixture.companion.sync(at: .milliseconds(20))
        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.execution)])
    }

    func testEmptyDurableStatusAppliesSignalOff() throws {
        let fixture = try ExecutionFixture()

        try fixture.companion.sync(at: .milliseconds(0))

        XCTAssertEqual(fixture.lighting.behaviors, [.off])
    }

    func testConcurrentHooksRemainAtomicWithinTheProductionLockBudget() throws {
        let fixture = try ExecutionFixture()
        let statusURL = fixture.statusURL

        DispatchQueue.concurrentPerform(iterations: 4) { index in
            let store = DurableStatusStore(url: statusURL)
            let hook = ProductionHookHandler(store: store, lockBudget: .milliseconds(100))
            let input = Data(
                """
                {"hook_event_name":"UserPromptSubmit","session_id":"session-\(index)","turn_id":"turn-1"}
                """.utf8
            )
            try! hook.handle(input, receivedAt: .milliseconds(0))
            for _ in 0..<10 {
                _ = try! store.load()
            }
        }

        XCTAssertEqual(try fixture.store.load().owners.count, 4)
    }

    func testHookLockWaitIsBoundedAndDoesNotTouchLighting() throws {
        let fixture = try ExecutionFixture(lockBudget: .milliseconds(30))
        let lockDescriptor = open(fixture.store.lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lockDescriptor, 0)
        defer { close(lockDescriptor) }
        XCTAssertEqual(flock(lockDescriptor, LOCK_EX), 0)
        defer { flock(lockDescriptor, LOCK_UN) }
        let started = ContinuousClock.now

        XCTAssertThrowsError(
            try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-1", at: 0)
        )

        XCTAssertLessThan(started.duration(to: .now), .milliseconds(250))
        XCTAssertTrue(fixture.lighting.behaviors.isEmpty)
    }

    func testRenewedExecutionSurvivesAStaleGenerationTimer() throws {
        let fixture = try ExecutionFixture()
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-1", at: 0)
        let staleExpiry = try XCTUnwrap(fixture.store.load().expiries.first)

        try fixture.handle("PostToolUse", session: "session-1", turn: "turn-1", at: 3_599_000)
        try fixture.companion.handle(expiry: staleExpiry, at: .milliseconds(3_600_000))

        XCTAssertEqual(try fixture.store.load().owners.count, 1)
        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.execution)])

        try fixture.companion.sync(at: .milliseconds(7_199_000))
        XCTAssertEqual(
            fixture.lighting.behaviors,
            [.signal(LocalProfile.default.execution), .off]
        )
    }

    func testOrphanedExecutionExpiresAfterOneHour() throws {
        let fixture = try ExecutionFixture()
        try fixture.handle("UserPromptSubmit", session: "orphaned", turn: "turn-1", at: 0)

        try fixture.companion.sync(at: .milliseconds(0))
        try fixture.companion.sync(at: .milliseconds(3_600_000))

        XCTAssertEqual(
            fixture.lighting.behaviors,
            [.signal(LocalProfile.default.execution), .off]
        )
        XCTAssertTrue(try fixture.store.load().owners.isEmpty)
    }
}

private final class ExecutionFixture {
    let directory: URL
    let statusURL: URL
    let store: DurableStatusStore
    let hook: ProductionHookHandler
    let lighting = RecordingCompanionLightingAdapter()
    lazy var companion = KeyphoreCompanion(store: store, profile: .default, lighting: lighting)

    init(lockBudget: Duration = .milliseconds(100)) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        statusURL = directory.appending(path: "status.json")
        store = DurableStatusStore(url: statusURL)
        hook = ProductionHookHandler(store: store, lockBudget: lockBudget)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func handle(
        _ event: String,
        session: String,
        agent: String? = nil,
        turn: String,
        at milliseconds: UInt64
    ) throws {
        var input: [String: Any] = [
            "hook_event_name": event,
            "session_id": session,
            "turn_id": turn,
        ]
        input["agent_id"] = agent
        try hook.handle(
            JSONSerialization.data(withJSONObject: input),
            receivedAt: .milliseconds(milliseconds)
        )
    }
}

private final class RecordingCompanionLightingAdapter: CompanionLightingApplying {
    private(set) var behaviors: [LightingBehavior] = []

    func apply(_ behavior: LightingBehavior) throws {
        behaviors.append(behavior)
    }
}
