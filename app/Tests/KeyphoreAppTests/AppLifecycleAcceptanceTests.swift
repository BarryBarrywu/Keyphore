import AppKit
import SwiftUI
import XCTest
import KeyphoreCore

@MainActor
final class AppLifecycleAcceptanceTests: XCTestCase {
    func testFinishedVisualConfirmationDoesNotExpandTheMainPanel() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignalPreviewStore(url: directory.appending(path: "preview.json"))
        for phase in [SignalPreviewPhase.confirmed, .rejected] {
            var record = try store.begin()
            record.phase = phase
            try store.save(record)
            let state = KeyphoreAppState(
                lifecycle: KeyphoreLifecycle(
                    health: AppHealth(), profiles: AppProfile(), durableStatus: AppDurableStatus(),
                    lighting: AppLighting(), runtime: AppRecordingRuntime()
                ),
                previewStore: store
            )
            let hosting = NSHostingController(rootView: KeyphorePopover(state: state))

            XCTAssertLessThanOrEqual(hosting.sizeThatFits(in: NSSize(width: 392, height: 0)).height, 370)
            XCTAssertEqual(try store.load()?.phase, phase)
        }
    }

    func testGeneralSettingsPersistWithoutStartingDiagnosticCollection() async throws {
        let suite = "keyphore-app-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        let provider = AppDiagnosticProvider(snapshot: DiagnosticSnapshot(
            appVersion: "0.1.0", macOSVersion: "macOS", codexHosts: [],
            integration: .notConfigured, keyboard: .disconnected
        ), onCollection: {})
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(), profiles: AppProfile(), durableStatus: AppDurableStatus(),
                lighting: AppLighting(), runtime: AppRecordingRuntime()
            ),
            diagnosticSnapshotProvider: provider.snapshot,
            preferencesStore: store
        )

        state.updatePreferences(AppPreferences(appearance: .dark, language: .simplifiedChinese))

        XCTAssertFalse(state.diagnosticReportIsRefreshing)
        XCTAssertFalse(state.diagnosticReportIsReady)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(store.load(), state.preferences)
        XCTAssertEqual(state.diagnosticReport.language, .simplifiedChinese)
        XCTAssertEqual(state.snapshot.profile, .default)
    }

    func testResettingSignalColorPersistsWithoutResettingOtherSignalSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalProfileStore(url: directory.appending(path: "profile.json"))
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(), profiles: PersistedAppProfile(store: store),
                durableStatus: AppDurableStatus(), lighting: AppLighting(), runtime: AppRecordingRuntime()
            ),
            profileStore: store
        )
        let custom = SignalAppearance(
            isVisible: false, color: SignalColor(red: 120, green: 30, blue: 90),
            brightness: SignalBrightness(percent: 42)!, pattern: .slowFlashing
        )
        state.updateAppearance(custom, for: .completion)
        state.updateCompletionDisplayDuration(CompletionDisplayDuration(seconds: 12)!)
        state.resetSignalColor(for: .completion)

        let reopened = try LocalProfileStore(url: store.url).load()
        XCTAssertEqual(reopened.completion.color, LocalProfile.default.completion.color)
        XCTAssertEqual(reopened.completion.brightness.percent, 42)
        XCTAssertEqual(reopened.completion.pattern, .slowFlashing)
        XCTAssertFalse(reopened.completion.isVisible)
        XCTAssertEqual(reopened.completionDisplayDuration.seconds, 12)
        XCTAssertEqual(reopened.execution, LocalProfile.default.execution)
        XCTAssertEqual(reopened.attention, LocalProfile.default.attention)
        XCTAssertEqual(state.snapshot.profile, reopened)
    }

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

    func testChangedHookUpdatePreparationUsesQuitGateAndCanRecoverTrustedHooks() throws {
        let runtime = AppRecordingRuntime()
        let state = makeState(runtime: runtime)

        try state.prepareForChangedHookUpdate()

        XCTAssertTrue(runtime.isQuitGateActive)
        XCTAssertEqual(runtime.actions, [.activateGate, .disableHooks])

        try state.recoverFromFailedChangedHookUpdate()

        XCTAssertFalse(runtime.isQuitGateActive)
        XCTAssertEqual(
            runtime.actions,
            [.activateGate, .disableHooks, .enableTrustedHooks, .clearGate]
        )
    }

    func testAppStateRequiresConfirmationThenCompletesManagedRemoval() async {
        let integration = AppManagedRemovalIntegration()
        let state = makeState(
            runtime: AppRecordingRuntime(),
            managedRemoval: ManagedRemoval(integration: integration)
        )

        state.presentManagedRemoval()

        XCTAssertTrue(state.removalIsPresented)
        XCTAssertEqual(state.removalSnapshot.components, Set(ManagedRemovalComponent.allCases))
        XCTAssertTrue(integration.actions.isEmpty)

        state.confirmManagedRemoval()
        while state.removalIsWorking {
            await Task.yield()
        }

        XCTAssertEqual(state.removalSnapshot.status, .completed)
        XCTAssertFalse(state.removalFailed)
        XCTAssertEqual(integration.actions.first, .begin)
        XCTAssertEqual(integration.actions.last, .complete)
        XCTAssertTrue(state.prepareToQuit())
    }

    func testInterruptedManagedRemovalIsPresentedForRepairOnLaunch() {
        let integration = AppManagedRemovalIntegration(status: .repairRequired)

        let state = makeState(
            runtime: AppRecordingRuntime(),
            managedRemoval: ManagedRemoval(integration: integration)
        )

        XCTAssertTrue(state.removalIsPresented)
        XCTAssertEqual(state.removalSnapshot.status, .repairRequired)
    }

    func testManagedRemovalFinishDismissesTheSheetBeforeRequestingTermination() async {
        var events: [String] = []
        let action = ManagedRemovalFinishAction {
            events.append("terminate")
        }

        action.perform {
            events.append("dismiss")
        }

        XCTAssertEqual(events, ["dismiss"])
        await Task.yield()
        XCTAssertEqual(events, ["dismiss", "terminate"])
    }

    private func makeState(
        runtime: AppRecordingRuntime,
        guidedSetup: GuidedSetup? = nil,
        managedRemoval: ManagedRemoval? = nil
    ) -> KeyphoreAppState {
        KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(),
                profiles: AppProfile(),
                durableStatus: AppDurableStatus(),
                lighting: AppLighting(),
                runtime: runtime
            ),
            guidedSetup: guidedSetup,
            managedRemoval: managedRemoval,
            updateRuntime: runtime
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

private struct PersistedAppProfile: LocalProfileProviding {
    let store: LocalProfileStore
    func currentProfile() -> LocalProfile { store.loadOrDefault() }
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

private final class AppManagedRemovalIntegration: ManagedRemovalIntegrating {
    enum Action: Equatable { case begin, signalOff, disableHooks, companion, plugin, state, verify, complete }

    private(set) var actions: [Action] = []
    private var status: ManagedRemovalStatus

    init(status: ManagedRemovalStatus = .reviewRequired) {
        self.status = status
    }

    func inspectManagedRemoval() -> ManagedRemovalStatus { status }
    func beginManagedRemoval() { actions.append(.begin); status = .repairRequired }
    func requestSignalOffForRemoval() { actions.append(.signalOff) }
    func disableOwnedHooksForRemoval() { actions.append(.disableHooks) }
    func removeCompanionAndBackgroundRegistration() { actions.append(.companion) }
    func removePluginAndHooks() { actions.append(.plugin) }
    func removeLocalProfileAndManagedRuntimeState() { actions.append(.state) }
    func verifyManagedRemoval() -> Bool { actions.append(.verify); return true }
    func completeManagedRemoval() { actions.append(.complete); status = .completed }
}
