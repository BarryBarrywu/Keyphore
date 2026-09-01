import AppKit
import XCTest
import KeyphoreCore

@MainActor
final class AppLifecycleAcceptanceTests: XCTestCase {
    func testAppStateCollectsTheReviewedDiagnosticPreviewOnlyWhenRequested() async {
        let diagnosticSnapshot = DiagnosticSnapshot(
            appVersion: "0.1.0 (1)",
            macOSVersion: "macOS 15.6.1",
            codexHosts: [.desktopApp],
            integration: .notConfigured,
            keyboard: .disconnected
        )
        let collected = expectation(description: "diagnostics collected")
        let provider = AppDiagnosticProvider(snapshot: diagnosticSnapshot) {
            collected.fulfill()
        }
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(),
                profiles: AppProfile(),
                durableStatus: AppDurableStatus(),
                lighting: AppLighting(),
                runtime: AppRecordingRuntime()
            ),
            diagnosticSnapshotProvider: provider.snapshot,
            diagnosticLanguage: .english
        )

        XCTAssertEqual(provider.callCount, 0)
        XCTAssertFalse(state.diagnosticReportIsReady)

        state.refresh()

        XCTAssertEqual(provider.callCount, 0)

        state.refreshDiagnosticReport()
        XCTAssertTrue(state.diagnosticReportIsRefreshing)
        await fulfillment(of: [collected], timeout: 1)
        while state.diagnosticReport.fields.first?.value != "0.1.0 (1)" {
            await Task.yield()
        }

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertTrue(state.diagnosticReportIsReady)
        XCTAssertFalse(state.diagnosticReportIsRefreshing)
        XCTAssertEqual(state.diagnosticReport.fields.map(\.id), DiagnosticField.ID.allCases)
        XCTAssertEqual(state.diagnosticReport.language, .english)
    }

    func testQuitBlocksCachedHooksAndReopensThroughAppLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "keyphore-app-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = QuitGateStore(url: directory.appending(path: "quit-gate"))
        let runtime = AppRecordingRuntime(gate: gate)
        let state = makeState(runtime: runtime)
        let delegate = KeyphoreAppDelegate()
        delegate.prepareToQuit = state.prepareToQuit

        XCTAssertEqual(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared), false)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateNow)
        XCTAssertEqual(runtime.actions, [.activateGate, .disableHooks, .clearState, .signalOff, .stop])

        let statusURL = directory.appending(path: "status.json")
        try ProductionHookHandler(
            store: DurableStatusStore(url: statusURL),
            quitGate: gate
        ).handle(Data(
            #"{"hook_event_name":"UserPromptSubmit","session_id":"cached","turn_id":"turn-1"}"#.utf8
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusURL.path))

        XCTAssertEqual(try state.reopenIfNeeded(), .restored)
        XCTAssertEqual(
            Array(runtime.actions.suffix(5)),
            [.clearState, .enableTrustedHooks, .start, .signalOff, .clearGate]
        )
    }

    func testLoginLaunchSettingUsesTheAppStateSeam() {
        let integration = AppSetupIntegration()
        let setup = GuidedSetup(
            hosts: AppHostDetector(),
            integration: integration,
            keyboard: AppKeyboardHealth()
        )
        let state = makeState(runtime: AppRecordingRuntime(), guidedSetup: setup)

        state.updateLoginLaunch(false)

        XCTAssertFalse(state.loginLaunchEnabled)
        XCTAssertEqual(integration.loginLaunchSelections, [false])
    }

    private func makeState(
        runtime: AppRecordingRuntime,
        guidedSetup: GuidedSetup? = nil
    ) -> KeyphoreAppState {
        KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(),
                profiles: AppProfile(),
                durableStatus: AppDurableStatus(),
                lighting: AppLighting(),
                runtime: runtime
            ),
            guidedSetup: guidedSetup
        )
    }
}

private final class AppDiagnosticProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let diagnosticSnapshot: DiagnosticSnapshot
    private let onCollection: @Sendable () -> Void
    private var calls = 0

    init(snapshot: DiagnosticSnapshot, onCollection: @escaping @Sendable () -> Void) {
        diagnosticSnapshot = snapshot
        self.onCollection = onCollection
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func snapshot() -> DiagnosticSnapshot {
        lock.withLock { calls += 1 }
        onCollection()
        return diagnosticSnapshot
    }
}

private final class AppRecordingRuntime: KeyphoreRuntimeManaging {
    enum Action: Equatable {
        case activateGate, disableHooks, clearState, signalOff, stop
        case start, enableTrustedHooks, clearGate
    }

    private let gate: QuitGateStore
    private(set) var actions: [Action] = []

    init(gate: QuitGateStore = QuitGateStore(
        url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    )) {
        self.gate = gate
    }

    var isQuitGateActive: Bool { gate.isActive }
    func activateQuitGate() throws { try gate.activate(); actions.append(.activateGate) }
    func disableOwnedHooks() { actions.append(.disableHooks) }
    func stopCompanion() { actions.append(.stop) }
    func clearManagedRuntimeState() { actions.append(.clearState) }
    func requestSignalOff() { actions.append(.signalOff) }
    func enableOwnedHooksIfTrusted() -> Bool { actions.append(.enableTrustedHooks); return true }
    func startCompanion() { actions.append(.start) }
    func clearQuitGate() throws { try gate.clear(); actions.append(.clearGate) }
}

private struct AppHealth: KeyphoreHealthProviding {
    func currentHealth() -> KeyphoreHealth { .configured(keyboard: .disconnected) }
}

private struct AppProfile: LocalProfileProviding {
    func currentProfile() -> LocalProfile { .default }
}

private struct AppDurableStatus: DurableStatusProviding {
    func currentOutcome() -> DurableStatusOutcome { .signalOff }
}

private final class AppLighting: LightingEmitting {
    func emit(_ behavior: LightingBehavior) {}
}

private struct AppHostDetector: CodexHostDetecting {
    func detectHosts() -> Set<CodexHost> { [.desktopApp] }
}

private struct AppKeyboardHealth: SetupKeyboardHealthProviding {
    func currentKeyboardHealth() -> KeyboardHealth { .disconnected }
}

private final class AppSetupIntegration: GuidedSetupIntegrating {
    private(set) var loginLaunchSelections: [Bool] = []
    private var loginLaunch = true

    func health() -> SetupIntegrationHealth { .notConfigured }
    func stage(_ hooks: [HookDefinition]) {}
    func installedHookHashes() -> [HookEvent: String] { HookDefinition.reviewedHashes }
    func trust(_ hooks: [HookDefinition]) {}
    func resetRuntimeState() {}
    func registerCompanion() {}
    func persistConfigured() {}
    func setLoginLaunchEnabled(_ enabled: Bool) {
        loginLaunch = enabled
        loginLaunchSelections.append(enabled)
    }
    func loginLaunchEnabled() -> Bool { loginLaunch }
}
