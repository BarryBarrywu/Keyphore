import Darwin
import Foundation
import KeyphoreCore
import XCTest

final class SignalFlowAcceptanceTests: XCTestCase {
    func testRuntimeReplacementClearsOwnersAndTurnHistory() throws {
        let fixture = try SignalFixture()
        try fixture.handle("UserPromptSubmit", session: "stale-session", turn: "turn-1", at: 0)

        try fixture.store.reset(lockBudget: .milliseconds(100))

        XCTAssertEqual(try fixture.store.load(), DurableStatus())
    }

    func testMainStopShowsCompletionForFiveSecondsThenTurnsSignalOff() throws {
        let fixture = try SignalFixture()
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-1", at: 0)
        try fixture.handle("Stop", session: "session-1", turn: "turn-1", at: 100)

        try fixture.companion.sync(at: .milliseconds(100))
        try fixture.companion.sync(at: .milliseconds(5_099))
        try fixture.companion.sync(at: .milliseconds(5_100))

        XCTAssertEqual(
            fixture.lighting.behaviors,
            [
                .signal(LocalProfile.default.completion),
                .off,
            ]
        )
    }

    func testCompletionUsesTheConfiguredDisplayDuration() throws {
        let fixture = try SignalFixture(completionDisplayDuration: .init(seconds: 1)!)
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-1", at: 0)
        try fixture.handle("Stop", session: "session-1", turn: "turn-1", at: 100)

        try fixture.companion.sync(at: .milliseconds(100))
        try fixture.companion.sync(at: .milliseconds(1_099))
        try fixture.companion.sync(at: .milliseconds(1_100))

        XCTAssertEqual(
            fixture.lighting.behaviors,
            [.signal(fixture.profile.completion), .off]
        )
    }

    func testExecutionOutranksCompletionAndSurvivesItsExpiry() throws {
        let fixture = try SignalFixture()
        try fixture.handle(
            "UserPromptSubmit",
            session: "session-complete",
            turn: "turn-1",
            at: 0
        )
        try fixture.handle("Stop", session: "session-complete", turn: "turn-1", at: 100)
        try fixture.handle(
            "UserPromptSubmit",
            session: "session-executing",
            turn: "turn-1",
            at: 200
        )

        try fixture.companion.sync(at: .milliseconds(200))
        try fixture.companion.sync(at: .milliseconds(5_100))

        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.execution)])
        let remaining = try fixture.store.load().owners
        XCTAssertEqual(remaining.map(\.id.sessionID), ["session-executing"])
    }

    func testRenewedExecutionSurvivesAStaleCompletionTimer() throws {
        let fixture = try SignalFixture()
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-1", at: 0)
        try fixture.handle("Stop", session: "session-1", turn: "turn-1", at: 100)
        let staleExpiry = try XCTUnwrap(fixture.store.load().expiries.first)

        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-2", at: 1_000)
        try fixture.companion.handle(expiry: staleExpiry, at: .milliseconds(5_100))

        XCTAssertEqual(try fixture.store.load().owners.map(\.signal), [.execution])
        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.execution)])
    }

    func testRenewedAttentionSurvivesAStaleCompletionTimer() throws {
        let fixture = try SignalFixture()
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-1", at: 0)
        try fixture.handle("Stop", session: "session-1", turn: "turn-1", at: 100)
        let staleExpiry = try XCTUnwrap(fixture.store.load().expiries.first)

        try fixture.handle("PermissionRequest", session: "session-1", turn: "turn-1", at: 1_000)
        try fixture.companion.handle(expiry: staleExpiry, at: .milliseconds(5_100))

        XCTAssertEqual(try fixture.store.load().owners.map(\.signal), [.attention])
        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.attention)])
    }

    func testFailureContentNeverCreatesATaskFailureSignal() throws {
        let fixture = try SignalFixture()
        try fixture.hook.handle(
            Data(
                """
                {"hook_event_name":"PostToolUse","session_id":"session-1","turn_id":"turn-1","tool_response":{"success":false,"output":"private failed tool output"},"terminal_output":"private terminal failure"}
                """.utf8
            ),
            receivedAt: .milliseconds(0)
        )
        try fixture.companion.sync(at: .milliseconds(0))

        try fixture.hook.handle(
            Data(
                """
                {"hook_event_name":"Stop","session_id":"session-1","turn_id":"turn-1","last_assistant_message":"the task failed"}
                """.utf8
            ),
            receivedAt: .milliseconds(100)
        )
        try fixture.companion.sync(at: .milliseconds(100))

        XCTAssertEqual(
            fixture.lighting.behaviors,
            [
                .signal(LocalProfile.default.execution),
                .signal(LocalProfile.default.completion),
            ]
        )
        let persisted = try String(contentsOf: fixture.statusURL, encoding: .utf8)
        XCTAssertFalse(persisted.contains("private failed tool output"))
        XCTAssertFalse(persisted.contains("private terminal failure"))
        XCTAssertFalse(persisted.contains("the task failed"))
    }

    func testAttentionOutranksCompletionRegardlessOfArrivalOrder() throws {
        for completionFirst in [true, false] {
            let fixture = try SignalFixture()
            if completionFirst {
                try fixture.handle("UserPromptSubmit", session: "completed", turn: "turn-1", at: 0)
                try fixture.handle("Stop", session: "completed", turn: "turn-1", at: 100)
                try fixture.handle("PermissionRequest", session: "attention", turn: "turn-1", at: 200)
            } else {
                try fixture.handle("PermissionRequest", session: "attention", turn: "turn-1", at: 0)
                try fixture.handle("UserPromptSubmit", session: "completed", turn: "turn-1", at: 100)
                try fixture.handle("Stop", session: "completed", turn: "turn-1", at: 200)
            }

            try fixture.companion.sync(at: .milliseconds(200))

            XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.attention)])
        }
    }

    @MainActor
    func testMenuDurableStatusAndLightingAgreeThroughCompletionExpiry() throws {
        let fixture = try SignalFixture()
        let menuLighting = RecordingMenuLightingAdapter()
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-1", at: 0)
        try fixture.handle("Stop", session: "session-1", turn: "turn-1", at: 100)

        try fixture.companion.sync(at: .milliseconds(100))
        let completion = lifecycleSnapshot(
            outcome: try fixture.store.outcome(at: .milliseconds(100)),
            lighting: menuLighting
        )

        try fixture.companion.sync(at: .milliseconds(5_100))
        let signalOff = lifecycleSnapshot(
            outcome: try fixture.store.outcome(at: .milliseconds(5_100)),
            lighting: menuLighting
        )

        XCTAssertEqual(completion.menuState, .ready)
        XCTAssertEqual(completion.durableStatus, .completion)
        XCTAssertEqual(completion.currentSignal, .completion)
        XCTAssertEqual(signalOff.menuState, .ready)
        XCTAssertEqual(signalOff.durableStatus, .signalOff)
        XCTAssertEqual(signalOff.currentSignal, .signalOff)
        XCTAssertEqual(
            fixture.lighting.behaviors,
            [.signal(LocalProfile.default.completion), .off]
        )
        XCTAssertEqual(
            menuLighting.behaviors,
            [.signal(LocalProfile.default.completion), .off]
        )
    }

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

    func testStopCompletionCannotClearAnotherSessionsAttention() throws {
        let fixture = try SignalFixture()
        for session in ["session-1", "session-2"] {
            try fixture.handle("PermissionRequest", session: session, turn: "turn-1", at: 0)
        }

        try fixture.handle("Stop", session: "session-1", turn: "turn-1", at: 100)
        try fixture.companion.sync(at: .milliseconds(100))

        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.attention)])
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: try fixture.store.load().owners.map {
                    ($0.id.sessionID, $0.signal)
                }
            ),
            ["session-1": .completion, "session-2": .attention]
        )
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

    func testMainOwnerCompletionCannotClearAnotherActiveSession() throws {
        let fixture = try SignalFixture()
        try fixture.handle("UserPromptSubmit", session: "session-1", turn: "turn-1", at: 0)
        try fixture.handle("UserPromptSubmit", session: "session-2", turn: "turn-1", at: 10)
        try fixture.handle("Stop", session: "session-1", turn: "turn-1", at: 20)

        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: try fixture.store.load().owners.map {
                    ($0.id.sessionID, $0.signal)
                }
            ),
            ["session-1": .completion, "session-2": .execution]
        )
    }

    func testMainOwnerCompletionLeavesChildExecutionInTheSameSession() throws {
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

        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: try fixture.store.load().owners.map {
                    ($0.id.agentID, $0.signal)
                }
            ),
            ["agent-1": .execution, "main": .completion]
        )
        try fixture.companion.sync(at: .milliseconds(20))
        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.execution)])
    }

    func testEmptyDurableStatusAppliesSignalOff() throws {
        let fixture = try SignalFixture()

        try fixture.companion.sync(at: .milliseconds(0))

        XCTAssertEqual(fixture.lighting.behaviors, [.off])
    }

    func testCompanionAcknowledgesSignalOffOnlyAfterApplyingIt() throws {
        let fixture = try SignalFixture()
        let acknowledgement = SignalOffAcknowledgementStore(
            url: fixture.directory.appending(path: "signal-off-ack")
        )
        let companion = KeyphoreCompanion(
            store: fixture.store,
            profile: fixture.profile,
            lighting: fixture.lighting,
            signalOffAcknowledgement: acknowledgement
        )

        XCTAssertFalse(acknowledgement.isAcknowledged)

        try companion.sync(at: .milliseconds(0))

        XCTAssertTrue(acknowledgement.isAcknowledged)
        XCTAssertEqual(fixture.lighting.behaviors, [.off])

        try acknowledgement.clear()
        try companion.sync(at: .milliseconds(1))

        XCTAssertTrue(acknowledgement.isAcknowledged)
        XCTAssertEqual(fixture.lighting.behaviors, [.off])
    }

    func testCachedHookInvocationAfterQuitReturnsWithoutWritingStatus() throws {
        let fixture = try SignalFixture()
        let quitGate = QuitGateStore(url: fixture.directory.appending(path: "quit-gate"))
        try quitGate.activate()
        let hook = ProductionHookHandler(
            store: fixture.store,
            quitGate: quitGate,
            profile: fixture.profile
        )
        let input = Data(
            """
            {"hook_event_name":"UserPromptSubmit","session_id":"cached","turn_id":"turn-1"}
            """.utf8
        )

        try hook.handle(input, receivedAt: .milliseconds(0))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.statusURL.path))
        XCTAssertTrue(try fixture.store.load().owners.isEmpty)
    }

    func testCachedHookInvocationAfterManagedRemovalReturnsWithoutRecreatingState() throws {
        let fixture = try SignalFixture()
        let hook = ProductionHookHandler(
            store: fixture.store,
            configuredStateURL: fixture.directory.appending(path: "setup.json"),
            profile: fixture.profile
        )
        let input = Data(
            #"{"hook_event_name":"UserPromptSubmit","session_id":"cached","turn_id":"turn-1"}"#.utf8
        )

        try hook.handle(input, receivedAt: .milliseconds(0))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.statusURL.path))
        XCTAssertTrue(try fixture.store.load().owners.isEmpty)
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

@MainActor
private func lifecycleSnapshot(
    outcome: DurableStatusOutcome,
    lighting: RecordingMenuLightingAdapter
) -> LifecycleSnapshot {
    KeyphoreLifecycle(
        health: SignalFlowHealthAdapter(),
        profiles: SignalFlowProfileAdapter(),
        durableStatus: SignalFlowDurableStatusAdapter(outcome: outcome),
        lighting: lighting,
        runtime: SignalFlowRuntimeAdapter()
    ).refresh()
}

private struct SignalFlowHealthAdapter: KeyphoreHealthProviding {
    func currentHealth() -> KeyphoreHealth {
        .configured(keyboard: .connected(protocolHealthy: true))
    }
}

private struct SignalFlowProfileAdapter: LocalProfileProviding {
    func currentProfile() -> LocalProfile { .default }
}

private struct SignalFlowDurableStatusAdapter: DurableStatusProviding {
    let outcome: DurableStatusOutcome

    func currentOutcome() -> DurableStatusOutcome { outcome }
}

private final class RecordingMenuLightingAdapter: LightingEmitting {
    private(set) var behaviors: [LightingBehavior] = []

    func emit(_ behavior: LightingBehavior) {
        behaviors.append(behavior)
    }
}

private final class SignalFlowRuntimeAdapter: KeyphoreRuntimeManaging {
    func activateQuitGate() {}
    func disableOwnedHooks() {}
    func stopCompanion() {}
    func clearManagedRuntimeState() {}
    func requestSignalOff() {}
    func enableOwnedHooksIfTrusted() -> Bool { true }
    func startCompanion() {}
    func clearQuitGate() {}
}

private final class SignalFixture {
    let directory: URL
    let statusURL: URL
    let store: DurableStatusStore
    let hook: ProductionHookHandler
    let profile: LocalProfile
    let lighting = RecordingCompanionLightingAdapter()
    lazy var companion = KeyphoreCompanion(store: store, profile: profile, lighting: lighting)

    init(
        lockBudget: Duration = .milliseconds(100),
        completionDisplayDuration: CompletionDisplayDuration = .fiveSeconds
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        statusURL = directory.appending(path: "status.json")
        store = DurableStatusStore(url: statusURL)
        let defaultProfile = LocalProfile.default
        profile = LocalProfile(
            execution: defaultProfile.execution,
            attention: defaultProfile.attention,
            completion: defaultProfile.completion,
            completionDisplayDuration: completionDisplayDuration
        )
        hook = ProductionHookHandler(
            store: store,
            lockBudget: lockBudget,
            profile: profile
        )
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
