import XCTest
import KeyphoreCore

@MainActor
final class AgentIntegrationsViewTests: XCTestCase {
    func testApprovedNativeSourceMakesAppConfiguredWithoutCodex() throws {
        let fixture = try AgentUIFixture(installPi: true)
        defer { fixture.cleanUp() }
        let state = fixture.state(hosts: [])

        XCTAssertEqual(state.setupSnapshot.phase, .codexHostMissing)
        XCTAssertTrue(state.hasReadyAgentSource)
        XCTAssertEqual(state.menuState, .configured)
        XCTAssertEqual(state.agentSourceSnapshots.first(where: { $0.source == .pi })?.approved, true)
    }

    func testSourceFailureDoesNotChangeAnotherApprovedSource() async throws {
        let fixture = try AgentUIFixture(installPi: true)
        defer { fixture.cleanUp() }
        let state = fixture.state(hosts: [])

        state.reviewAgentIntegration(.claudeCode)
        await state.waitForAgentIntegrationOperation()

        XCTAssertTrue(state.agentIntegrationFailedSources.contains(.claudeCode))
        XCTAssertFalse(state.agentIntegrationFailedSources.contains(.pi))
        XCTAssertEqual(state.agentSourceSnapshots.first(where: { $0.source == .pi })?.approved, true)
        XCTAssertNil(state.agentIntegrationReview)
    }

    func testRemovalRequiresConfirmationAndRemovesOnlySelectedSource() async throws {
        let fixture = try AgentUIFixture(installPi: true)
        defer { fixture.cleanUp() }
        let state = fixture.state(hosts: [])

        state.requestAgentIntegrationRemoval(.pi)
        XCTAssertEqual(state.agentRemovalSource, .pi)
        XCTAssertTrue(try fixture.manager.hasReadySource())

        state.confirmAgentIntegrationRemoval()
        await state.waitForAgentIntegrationOperation()

        XCTAssertFalse(try fixture.manager.hasReadySource())
        XCTAssertEqual(state.agentSourceSnapshots.first(where: { $0.source == .pi })?.installed, false)
    }

    func testCodexReviewFlowStillWinsWhenNoNativeSourceIsApproved() throws {
        let fixture = try AgentUIFixture(installPi: false)
        defer { fixture.cleanUp() }
        let state = fixture.state(hosts: [.desktopApp])

        XCTAssertEqual(state.setupSnapshot.phase, .hookReview)
        XCTAssertFalse(state.hasReadyAgentSource)
        XCTAssertEqual(state.menuState, .configurationRequired)
    }

    func testNativeCLIInspectionAndPostRemovalRefreshStayOffMainThread() async throws {
        let fixture = try AgentNativeUIFixture()
        defer { fixture.cleanUp() }
        fixture.queries.arm()

        let state = makeAgentUIState(manager: fixture.manager, hosts: [], healthURL: fixture.root.appending(path: "keyboard-health.json"))
        await state.waitForAgentSnapshotRefresh()

        XCTAssertGreaterThan(fixture.queries.count, 0)
        XCTAssertEqual(fixture.queries.mainThreadCount, 0)
        XCTAssertEqual(
            state.agentSourceSnapshots.first(where: { $0.source == .qodercli })?.approved,
            true
        )

        state.requestAgentIntegrationRemoval(.qodercli)
        state.confirmAgentIntegrationRemoval()
        await state.waitForAgentIntegrationOperation()

        XCTAssertEqual(fixture.queries.mainThreadCount, 0)
        XCTAssertEqual(
            state.agentSourceSnapshots.first(where: { $0.source == .qodercli })?.installed,
            false
        )
    }
}

private final class AgentUIFixture {
    let root: URL
    var home: URL { root.appending(path: "home") }
    var bin: URL { root.appending(path: "bin") }
    var helper: URL { root.appending(path: "keyphore") }
    let manager: SystemAgentIntegrations

    init(installPi: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "keyphore-agent-ui-\(UUID().uuidString)")
        self.root = root
        let bin = root.appending(path: "bin")
        let home = root.appending(path: "home")
        let helper = root.appending(path: "keyphore")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let pi = bin.appending(path: "pi")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: pi)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        let manager = SystemAgentIntegrations(
            homeDirectory: home,
            environment: ["PATH": bin.path],
            helperURL: helper,
            commandRunner: { _, _ in Data() },
            assetProvider: { source, _ in
                source == .pi ? ["keyphore.ts": Data("pi extension".utf8)] : [:]
            },
            prepareRuntime: {}
        )
        self.manager = manager
        if installPi {
            let review = try manager.review(.pi)
            try manager.install(.pi, reviewedDigest: review.digest)
        }
    }

    @MainActor
    func state(hosts: Set<CodexHost>) -> KeyphoreAppState {
        makeAgentUIState(manager: manager, hosts: hosts, healthURL: root.appending(path: "keyboard-health.json"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class AgentNativeUIFixture {
    let root: URL
    let manager: SystemAgentIntegrations
    let queries: NativeQueryRecorder

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "keyphore-agent-native-ui-\(UUID().uuidString)")
        self.root = root
        let queries = NativeQueryRecorder()
        self.queries = queries
        let home = root.appending(path: "home")
        let bin = root.appending(path: "bin")
        let helper = root.appending(path: "keyphore")
        let cache = root.appending(path: "cache/keyphore-qodercli")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let executable = bin.appending(path: "qodercli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var registered = false
        let manager = SystemAgentIntegrations(
            homeDirectory: home,
            environment: ["PATH": bin.path],
            helperURL: helper,
            commandRunner: { _, arguments in
                if arguments.prefix(2) == ["plugins", "list"] {
                    queries.record()
                    let rows: [[String: Any]] = registered ? [[
                        "id": "keyphore-qodercli@local",
                        "name": "keyphore-qodercli",
                        "scope": "user",
                        "enabled": true,
                        "installPath": cache.path,
                    ]] : []
                    return try JSONSerialization.data(withJSONObject: rows)
                }
                if arguments.prefix(2) == ["plugins", "install"] {
                    try FileManager.default.createDirectory(
                        at: cache.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(
                        at: URL(fileURLWithPath: arguments[2]),
                        to: cache
                    )
                    registered = true
                    return try JSONSerialization.data(withJSONObject: ["path": cache.path])
                }
                if arguments.prefix(2) == ["plugins", "uninstall"] {
                    registered = false
                    try FileManager.default.removeItem(at: cache)
                }
                return Data()
            },
            assetProvider: { source, _ in
                guard source == .qodercli else { return [:] }
                return [
                    ".qoder-plugin/plugin.json": Data("{}".utf8),
                    "hooks/hooks.json": Data("{}".utf8),
                ]
            },
            prepareRuntime: {}
        )
        self.manager = manager
        let review = try manager.review(.qodercli)
        try manager.install(.qodercli, reviewedDigest: review.digest)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class NativeQueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var isArmed = false
    private var queryCount = 0
    private var mainQueries = 0

    var count: Int { lock.withLock { queryCount } }
    var mainThreadCount: Int { lock.withLock { mainQueries } }

    func arm() { lock.withLock { isArmed = true } }

    func record() {
        lock.withLock {
            guard isArmed else { return }
            queryCount += 1
            if Thread.isMainThread { mainQueries += 1 }
        }
    }
}

@MainActor
private func makeAgentUIState(
    manager: SystemAgentIntegrations,
    hosts: Set<CodexHost>,
    healthURL: URL
) -> KeyphoreAppState {
        let health = SystemKeyphoreHealthAdapter(isConfigured: false, keyboardHealth: KeyboardHealthStore(url: healthURL))
        let runtime = AgentUIRuntime()
        return KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: health,
                profiles: AgentUIProfile(),
                durableStatus: AgentUIDurableStatus(),
                lighting: AgentUILighting(),
                runtime: runtime
            ),
            guidedSetup: GuidedSetup(
                hosts: AgentUIHostDetector(hosts: hosts),
                integration: AgentUISetupIntegration(),
                keyboard: AgentUIKeyboardHealth()
            ),
            systemHealth: health,
            agentIntegrations: manager,
            updateRuntime: runtime
        )
}

private struct AgentUIHostDetector: CodexHostDetecting {
    let hosts: Set<CodexHost>
    func detectHosts() -> Set<CodexHost> { hosts }
}

private final class AgentUISetupIntegration: GuidedSetupIntegrating {
    func health() -> SetupIntegrationHealth { .notConfigured }
    func stage(_ hooks: [HookDefinition]) {}
    func installedHookHashes() -> [HookEvent: String] { [:] }
    func trust(_ hooks: [HookDefinition]) {}
    func resetRuntimeState() {}
    func registerCompanion() {}
    func persistConfigured() {}
    func setLoginLaunchEnabled(_ enabled: Bool) {}
}

private struct AgentUIKeyboardHealth: SetupKeyboardHealthProviding {
    func currentKeyboardHealth() -> KeyboardHealth { .disconnected }
}

private struct AgentUIProfile: LocalProfileProviding {
    func currentProfile() -> LocalProfile { .default }
}

private struct AgentUIDurableStatus: DurableStatusProviding {
    func currentOutcome() -> DurableStatusOutcome { .signalOff }
}

private final class AgentUILighting: LightingEmitting {
    func emit(_ behavior: LightingBehavior) {}
}

private final class AgentUIRuntime: KeyphoreRuntimeManaging {
    func activateQuitGate() {}
    func disableOwnedHooks() {}
    func stopCompanion() {}
    func clearManagedRuntimeState() {}
    func requestSignalOff() {}
    func enableOwnedHooksIfTrusted() -> Bool { true }
    func startCompanion() {}
    func clearQuitGate() {}
}
