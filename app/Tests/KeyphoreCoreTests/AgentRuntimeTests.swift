import Darwin
import Foundation
import XCTest
@testable import KeyphoreCore

final class AgentRuntimeTests: XCTestCase {
    private var directory: URL!
    private var store: DurableStatusStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "keyphore-agent-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DurableStatusStore(url: directory.appending(path: "status.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func apply(_ kind: AgentSignalEvent.Kind, source: AgentSource = .claudeCode,
                       session: String = "same-session", agent: String = "main", turn: String? = nil,
                       request: String? = nil) throws {
        try store.apply(AgentSignalEvent(source: source, kind: kind, sessionID: session, agentID: agent,
                                        turnID: turn, requestID: request), at: .milliseconds(1_000),
                        completionLifetime: .seconds(10), lockBudget: .seconds(2))
    }

    func testProductSessionAndChildIsolation() throws {
        try apply(.turnStart, source: .codex, turn: "codex-turn")
        try apply(.turnStart, turn: "parent")
        try apply(.agentStart, agent: "child", turn: "child-turn")
        try apply(.sessionStart, agent: "child")
        XCTAssertEqual(Set(try store.load().owners.map(\.id.product)), ["codex", "claude-code"])
        try apply(.agentStart, agent: "child", turn: "child-turn-2")
        try apply(.agentEnd, agent: "child")
        XCTAssertEqual(try store.load().owners.count, 2)
        try apply(.sessionStart)
        XCTAssertEqual(try store.load().owners.map(\.id.product), ["codex"])
        try apply(.turnStart, source: .pi)
        try store.removeProduct(.pi, lockBudget: .seconds(1))
        XCTAssertEqual(try store.load().owners.map(\.id.product), ["codex"])
    }

    func testRequestsAndChildrenResolveIndependently() throws {
        try apply(.turnStart)
        try apply(.agentStart, agent: "child")
        try apply(.attention, request: "a")
        try apply(.attention, request: "b")
        try apply(.attention, agent: "child", request: "c")
        try apply(.attentionResolved, request: "a")
        try apply(.working)
        XCTAssertEqual(try store.load().owners.filter { $0.signal == .attention }.count, 2)
        try apply(.attentionResolved, request: "unknown")
        XCTAssertEqual(try store.load().owners.filter { $0.signal == .attention }.count, 2)
        try apply(.attentionResolved, request: "b")
        let owners = try store.load().owners
        XCTAssertEqual(owners.first { $0.id.agentID == "main" }?.signal, .execution)
        XCTAssertEqual(owners.first { $0.id.agentID == "child" }?.signal, .attention)
    }

    func testNamedReplyDoesNotClearIndependentUnkeyedAttention() throws {
        try apply(.turnStart)
        try apply(.attention)
        try apply(.attention, request: "named")
        try apply(.attentionResolved, request: "named")
        XCTAssertEqual(try store.load().owners.first?.signal, .attention)
        try apply(.attentionResolved, request: "tool-id-not-on-original-notification")
        XCTAssertEqual(try store.load().owners.first?.signal, .execution)
    }

    func testNativeStaleEventsCannotCompleteOrCancelNewTurn() throws {
        try apply(.turnStart, source: .grok, turn: "one")
        try apply(.turnStart, source: .grok, turn: "two")
        try apply(.turnComplete, source: .grok, turn: "one")
        try apply(.turnCancelled, source: .grok, turn: "one")
        try apply(.turnStart, source: .grok, turn: "one")
        XCTAssertEqual(try store.load().owners.first?.turnID, "two")
        XCTAssertEqual(try store.load().owners.first?.signal, .execution)
        try apply(.turnComplete, source: .grok, turn: "two")
        XCTAssertEqual(try store.load().owners.first?.signal, .completion)
        try apply(.turnCancelled, source: .grok, turn: "two")
        XCTAssertTrue(try store.load().owners.isEmpty)
        try apply(.working, source: .grok, turn: "two")
        XCTAssertTrue(try store.load().owners.isEmpty)
    }

    func testMissingTurnsNeverInventActivityAndBindAtomicallyAcrossWriters() throws {
        try apply(.attention, request: "before-start")
        try apply(.turnComplete)
        XCTAssertTrue(try store.load().owners.isEmpty)
        try apply(.turnStart)
        let firstTurn = try XCTUnwrap(store.load().owners.first?.turnID)
        let url = store.url
        let errors = RuntimeErrors()
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                try DurableStatusStore(url: url).apply(
                    AgentSignalEvent(source: .claudeCode, kind: .attention, sessionID: "same-session",
                                     requestID: "request-\(index)"),
                    at: .milliseconds(1_000), completionLifetime: .seconds(10), lockBudget: .seconds(3))
            } catch { errors.append(error) }
        }
        XCTAssertEqual(errors.count, 0)
        XCTAssertEqual(try store.load().currentOwnerTurns.first?.pendingRequestIDs.count, 20)
        XCTAssertEqual(try store.load().owners.first?.turnID, firstTurn)
        try apply(.turnCancelled)
        XCTAssertTrue(try store.load().owners.isEmpty)
        try apply(.turnStart)
        XCTAssertNotEqual(try store.load().owners.first?.turnID, firstTurn)
        XCTAssertEqual(try store.load().currentOwnerTurns.first?.pendingRequestIDs, [])
    }

    func testNativeNormalizationIgnoresSensitiveDataAndUnsafeChildIdentity() throws {
        let payload = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"session","prompt":"SECRET","transcript_path":"/do/not/read","tool_input":{"command":"SECRET"},"product":"codex"}"#.utf8)
        let event = try XCTUnwrap(AgentHookNormalizer.normalize(payload, source: .claudeCode))
        XCTAssertEqual(event, AgentSignalEvent(source: .claudeCode, kind: .turnStart, sessionID: "session"))
        try store.apply(event, at: .milliseconds(0), completionLifetime: .seconds(10), lockBudget: .seconds(1))
        XCTAssertFalse(String(decoding: try Data(contentsOf: store.url), as: UTF8.self).contains("SECRET"))
        for source in [AgentSource.claudeCode, .qodercli] {
            XCTAssertNil(try AgentHookNormalizer.normalize(Data(#"{"hook_event_name":"SubagentStop","session_id":"s"}"#.utf8), source: source))
        }
        XCTAssertThrowsError(try AgentHookNormalizer.normalize(Data(#"{"event":"working","session_id":42}"#.utf8), source: .pi))
        XCTAssertThrowsError(try AgentHookNormalizer.normalize(Data("[]".utf8), source: .grok))
        XCTAssertThrowsError(try AgentHookNormalizer.normalize(Data(repeating: 0, count: 1_048_577), source: .grok))
        XCTAssertNil(try AgentHookNormalizer.normalize(Data(#"{"event":"attention","session_id":"s"}"#.utf8), source: .pi))
    }

    func testGrokCancellationAndSessionEndNeverSignalCompletion() throws {
        for name in ["StopFailure", "StopCancelled"] {
            let json = Data("{\"hook_event_name\":\"\(name)\",\"sessionId\":\"s\",\"promptId\":\"p\"}".utf8)
            XCTAssertEqual(try AgentHookNormalizer.normalize(json, source: .grok)?.kind, .turnCancelled)
        }
        for reason in ["channel_closed", "shutdown"] {
            let json = Data("{\"hookEventName\":\"stop\",\"sessionId\":\"s\",\"reason\":\"\(reason)\"}".utf8)
            XCTAssertEqual(try AgentHookNormalizer.normalize(json, source: .grok)?.kind, .sessionEnd)
        }
        XCTAssertNil(try AgentHookNormalizer.normalize(Data(#"{"hook_event_name":"SubagentStop","sessionId":"s","subagentType":"explore"}"#.utf8), source: .grok))
        XCTAssertNil(try AgentHookNormalizer.normalize(Data(#"{"hook_event_name":"StopCancelled","sessionId":"s","subagentType":"explore"}"#.utf8), source: .grok))
        XCTAssertNil(try AgentHookNormalizer.normalize(Data(#"{"hook_event_name":"Notification","sessionId":"s","notificationType":"idle_prompt","message":"Completed successfully"}"#.utf8), source: .grok))
        XCTAssertEqual(try AgentHookNormalizer.normalize(Data(#"{"hookEventName":"notification","sessionId":"s","notificationType":"permission_prompt"}"#.utf8), source: .grok)?.kind, .attention)
        XCTAssertNil(try AgentHookNormalizer.normalize(Data(#"{"hook_event_name":"PermissionRequest","sessionId":"s"}"#.utf8), source: .grok))
    }

    func testAuthorizationIsRecheckedOnlyAfterTakingStatusLock() throws {
        let descriptor = open(store.lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        let authorizationChecked = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let gate = QuitGateStore(url: directory.appending(path: "quit-gate"))
        let localStore = try XCTUnwrap(store)
        let errors = RuntimeErrors()
        DispatchQueue.global().async {
            do {
                try localStore.apply(
                    AgentSignalEvent(source: .claudeCode, kind: .turnStart, sessionID: "s"),
                    at: .milliseconds(0), completionLifetime: .seconds(10), lockBudget: .seconds(2),
                    isAuthorized: {
                        authorizationChecked.signal()
                        return !gate.isActive
                    })
            } catch { errors.append(error) }
            finished.signal()
        }
        XCTAssertEqual(authorizationChecked.wait(timeout: .now() + 0.05), .timedOut)
        try gate.activate()
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(errors.count, 0)
        XCTAssertTrue(try store.load().owners.isEmpty)
    }

    func testGrokNullOrEmptySubagentTypeIsNotAChild() throws {
        for childType in ["null", "\"\""] {
            let data = Data("{\"hook_event_name\":\"Stop\",\"sessionId\":\"s\",\"promptId\":\"p\",\"subagentType\":\(childType)}".utf8)
            XCTAssertEqual(try AgentHookNormalizer.normalize(data, source: .grok)?.kind, .turnComplete)
        }
    }

    func testConsentIsPerSourceAndBoundToRuntimeAndQuitGate() throws {
        let runtime = directory.appending(path: "keyphore")
        let bytes = Data("reviewed runtime".utf8)
        try bytes.write(to: runtime)
        let consent = AgentIntegrationConsentStore(url: directory.appending(path: "consent.json"))
        let gate = QuitGateStore(url: directory.appending(path: "quit-gate"))
        let handler = AgentHookHandler(store: store, source: .claudeCode, consentStore: consent,
                                       runtimeURL: runtime, quitGate: gate, environment: [:])
        let input = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s"}"#.utf8)
        try handler.handle(input)
        XCTAssertTrue(try store.load().owners.isEmpty)
        var manifest = AgentIntegrationManifest(sources: ["qodercli": AgentSourceConsent(
            enabled: true, definitionDigest: "reviewed", runtimeDigest: ManagedRuntimeIntegrity.digest(bytes), assets: [:])])
        try consent.save(manifest)
        try handler.handle(input)
        XCTAssertTrue(try store.load().owners.isEmpty)
        manifest.sources["claude-code"] = manifest.sources["qodercli"]
        try consent.save(manifest)
        try gate.activate()
        try handler.handle(input)
        XCTAssertTrue(try store.load().owners.isEmpty)
        try gate.clear()
        for importedSource in [AgentSource.claudeCode, .qodercli] {
            let imported = AgentHookHandler(store: store, source: importedSource, consentStore: consent,
                                           runtimeURL: runtime, quitGate: gate,
                                           environment: ["GROK_PLUGIN_ROOT": "/plugins/imported-claude"])
            try imported.handle(input)
            XCTAssertTrue(try store.load().owners.isEmpty)
        }
        try handler.handle(input)
        XCTAssertEqual(try store.load().owners.count, 1)
        try store.removeProduct(.claudeCode, lockBudget: .seconds(1))
        manifest.sources["claude-code"]?.enabled = false
        try consent.save(manifest)
        try handler.handle(input)
        XCTAssertTrue(try store.load().owners.isEmpty)
        manifest.sources["claude-code"]?.enabled = true
        try consent.save(manifest)
        try Data("changed runtime".utf8).write(to: runtime)
        try handler.handle(input)
        XCTAssertTrue(try store.load().owners.isEmpty)
    }
}

private final class RuntimeErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    func append(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
}
