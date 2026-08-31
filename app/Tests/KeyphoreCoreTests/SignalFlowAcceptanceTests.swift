import Darwin
import Foundation
import KeyphoreCore
import XCTest

final class SignalFlowAcceptanceTests: XCTestCase {
    func testPermissionRequestOutranksExecutionThenReleasesBackToExecution() throws {
        let fixture = try SignalFixture()
        try fixture.handle("UserPromptSubmit", session: "executing", turn: "turn-1", at: 0)
        try fixture.handle(
            "PermissionRequest",
            session: "attention",
            agent: "agent-7",
            turn: "turn-1",
            at: 100
        )

        try fixture.companion.sync(at: .milliseconds(100))

        try fixture.handle(
            "PostToolUse",
            session: "attention",
            agent: "agent-7",
            turn: "turn-1",
            at: 200
        )
        try fixture.companion.sync(at: .milliseconds(200))

        XCTAssertEqual(
            fixture.lighting.behaviors,
            [
                .signal(LocalProfile.default.attention),
                .signal(LocalProfile.default.execution),
            ]
        )
    }

    func testAttentionOwnersReleaseIndependentlyBeforeRevealingExecution() throws {
        let fixture = try SignalFixture()
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-1", at: 0)
        for agent in ["agent-1", "agent-2"] {
            try fixture.handle(
                "PermissionRequest",
                session: "session-1",
                agent: agent,
                turn: "turn-1",
                at: 100
            )
        }

        try fixture.companion.sync(at: .milliseconds(100))
        try fixture.handle(
            "PostToolUse",
            session: "session-1",
            agent: "agent-1",
            turn: "turn-1",
            at: 200
        )
        try fixture.companion.sync(at: .milliseconds(200))
        try fixture.handle(
            "SubagentStop",
            session: "session-1",
            agent: "agent-2",
            turn: "turn-1",
            at: 300
        )
        try fixture.companion.sync(at: .milliseconds(300))

        XCTAssertEqual(
            fixture.lighting.behaviors,
            [
                .signal(LocalProfile.default.attention),
                .signal(LocalProfile.default.execution),
            ]
        )
    }

    func testRenewedAttentionSurvivesItsStaleGenerationTimer() throws {
        let fixture = try SignalFixture()
        try fixture.handle("PermissionRequest", session: "session-1", turn: "turn-1", at: 0)
        let staleExpiry = try XCTUnwrap(fixture.store.load().expiries.first)

        try fixture.handle(
            "PermissionRequest",
            session: "session-1",
            turn: "turn-1",
            at: 1_000
        )
        try fixture.companion.handle(expiry: staleExpiry, at: .milliseconds(3_600_000))

        XCTAssertEqual(try fixture.store.load().owners.map(\.signal), [.attention])
        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.attention)])
    }

    func testLaterExecutionCannotHideAnotherSessionsAttention() throws {
        let fixture = try SignalFixture()
        try fixture.handle("PermissionRequest", session: "attention", turn: "turn-1", at: 0)
        try fixture.handle("UserPromptSubmit", session: "execution", turn: "turn-1", at: 10)

        try fixture.companion.sync(at: .milliseconds(10))

        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.attention)])
    }

    func testStaleAttentionExpiresAfterOneHourAndRevealsRenewedExecution() throws {
        let fixture = try SignalFixture()
        try fixture.handle("UserPromptSubmit", session: "executing", turn: "turn-1", at: 0)
        try fixture.handle("PermissionRequest", session: "stale", turn: "turn-1", at: 0)

        try fixture.companion.sync(at: .milliseconds(0))
        try fixture.handle(
            "PostToolUse",
            session: "executing",
            turn: "turn-1",
            at: 1_800_000
        )
        try fixture.companion.sync(at: .milliseconds(3_600_000))

        XCTAssertEqual(
            fixture.lighting.behaviors,
            [
                .signal(LocalProfile.default.attention),
                .signal(LocalProfile.default.execution),
            ]
        )
        XCTAssertFalse(try fixture.store.load().owners.contains { $0.id.sessionID == "stale" })
    }

    func testNewPromptClearsAttentionFromTheSameSession() throws {
        let fixture = try SignalFixture()
        try fixture.handle(
            "PermissionRequest",
            session: "session-1",
            agent: "stale-agent",
            turn: "turn-1",
            at: 0
        )
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-2", at: 100)

        try fixture.companion.sync(at: .milliseconds(100))

        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.execution)])
        XCTAssertEqual(try fixture.store.load().owners.map(\.signal), [.execution])
    }

    func testOlderTurnAttentionCannotOverwriteCurrentSessionFacts() throws {
        let fixture = try SignalFixture()
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-1", at: 0)
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-2", at: 10)

        try fixture.handle("PermissionRequest", session: "session-1", turn: "turn-1", at: 20)

        let owners = try fixture.store.load().owners
        XCTAssertEqual(owners.map(\.turnID), ["turn-2"])
        XCTAssertEqual(owners.map(\.signal), [.execution])
    }

    func testExecutionStatusFromBeforeAttentionSupportRemainsReadable() throws {
        let fixture = try SignalFixture()
        try Data(
            """
            {"current_owner_turns":[],"generation":1,"owners":[{"expires_at":{"millisecondsSince1970":3600000},"generation":1,"id":{"agent_id":"main","product":"codex","session_id":"session-1"},"turn_id":"turn-1"}]}
            """.utf8
        ).write(to: fixture.statusURL)

        XCTAssertEqual(try fixture.store.load().owners.map(\.signal), [.execution])
    }

    func testPrivatePayloadCannotEnterHookRecordDurableStatusOrUIOutcome() throws {
        let fixture = try SignalFixture()
        let privateValues = [
            "private tool input",
            "private approval reason",
            "/private/transcript.jsonl",
            "private tool output",
        ]
        let input: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "session-7",
            "agent_id": "agent-1",
            "turn_id": "turn-3",
            "tool_input": privateValues[0],
            "reason": privateValues[1],
            "transcript_path": privateValues[2],
            "tool_output": privateValues[3],
        ]

        let inputData = try JSONSerialization.data(withJSONObject: input)
        let sanitizedRecord = try PrivacyAllowedHookRecord(
            jsonData: inputData,
            receivedAt: "0"
        ).encoded()
        try fixture.hook.handle(inputData, receivedAt: .milliseconds(0))

        let persisted = try String(contentsOf: fixture.statusURL, encoding: .utf8)
        let sanitized = String(decoding: sanitizedRecord, as: UTF8.self)
        for privateValue in privateValues {
            XCTAssertFalse(persisted.contains(privateValue))
            XCTAssertFalse(sanitized.contains(privateValue))
        }
        XCTAssertEqual(try fixture.store.outcome(at: .milliseconds(0)), .attention)
    }

    func testSessionStartClearsEveryAttentionOwnerInItsSession() throws {
        let fixture = try SignalFixture()
        try fixture.handle(
            "PermissionRequest",
            session: "session-1",
            agent: "agent-1",
            turn: "turn-1",
            at: 0
        )

        try fixture.hook.handle(
            Data("""
            {"hook_event_name":"SessionStart","session_id":"session-1"}
            """.utf8),
            receivedAt: .milliseconds(100)
        )
        try fixture.companion.sync(at: .milliseconds(100))

        XCTAssertTrue(try fixture.store.load().owners.isEmpty)
        XCTAssertEqual(fixture.lighting.behaviors, [.off])
    }

    func testStopCannotClearAnotherSessionsAttention() throws {
        let fixture = try SignalFixture()
        for session in ["session-1", "session-2"] {
            try fixture.handle("PermissionRequest", session: session, turn: "turn-1", at: 0)
        }

        try fixture.handle("Stop", session: "session-1", turn: "turn-1", at: 100)
        try fixture.companion.sync(at: .milliseconds(100))

        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.attention)])
        XCTAssertEqual(try fixture.store.load().owners.map(\.id.sessionID), ["session-2"])
    }

    func testProductionHookPersistsPrivateSafeExecutionAndCompanionAppliesDefaultBlue() throws {
        let fixture = try SignalFixture()
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
                SignalOwnerID(product: "codex", sessionID: "session-7", agentID: "main")
            ])

        try fixture.companion.sync(at: .milliseconds(0))

        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.execution)])
    }

    func testSubagentEndingLeavesMainExecutionOwnerActive() throws {
        let fixture = try SignalFixture()
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
        let fixture = try SignalFixture()
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-1", at: 0)
        try fixture.handle("UserPromptSubmit", session: "session-2", turn: "turn-1", at: 10)
        try fixture.handle("Stop", session: "session-1", turn: "turn-1", at: 20)

        let status = try fixture.store.load()
        XCTAssertEqual(status.owners.map(\.id.sessionID), ["session-2"])
    }

    func testMainOwnerEndingLeavesChildExecutionInTheSameSession() throws {
        let fixture = try SignalFixture()
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
        let fixture = try SignalFixture()

        try fixture.companion.sync(at: .milliseconds(0))

        XCTAssertEqual(fixture.lighting.behaviors, [.off])
    }

    func testConcurrentHooksRemainAtomicWithinTheProductionLockBudget() throws {
        let fixture = try SignalFixture()
        let statusURL = fixture.statusURL

        DispatchQueue.concurrentPerform(iterations: 4) { index in
            let store = DurableStatusStore(url: statusURL)
            let hook = ProductionHookHandler(store: store, lockBudget: .milliseconds(100))
            let event = index == 0 ? "PermissionRequest" : "UserPromptSubmit"
            let input = Data(
                """
                {"hook_event_name":"\(event)","session_id":"session-\(index)","turn_id":"turn-1"}
                """.utf8
            )
            try! hook.handle(input, receivedAt: .milliseconds(0))
            for _ in 0..<10 {
                _ = try! store.load()
            }
        }

        XCTAssertEqual(try fixture.store.load().owners.count, 4)
        XCTAssertEqual(try fixture.store.outcome(at: .milliseconds(0)), .active([.attention, .execution]))
    }

    func testHookLockWaitIsBoundedAndDoesNotTouchLighting() throws {
        let fixture = try SignalFixture(lockBudget: .milliseconds(30))
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
        let fixture = try SignalFixture()
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
        let fixture = try SignalFixture()
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

private final class SignalFixture {
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
