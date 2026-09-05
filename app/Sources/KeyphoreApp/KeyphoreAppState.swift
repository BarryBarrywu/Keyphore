import Foundation
import KeyphoreCore

@MainActor
final class KeyphoreAppState: ObservableObject {
    @Published var selectedSettingsTab: SettingsTab = .lights
    var openSettings: (() -> Void)?
    @Published private(set) var isStarting = false
    private var startupTask: Task<Void, Never>?
    private var inspectionIsRunning = false
    private var inspectionTask: Task<Void, Never>?
    private var lastSetupInspection: ContinuousClock.Instant?
    @Published private(set) var snapshot: LifecycleSnapshot
    @Published private(set) var setupSnapshot: GuidedSetupSnapshot
    @Published private(set) var setupFailed = false
    @Published private(set) var setupHooksChanged = false
    @Published private(set) var setupIsWorking = false
    @Published private(set) var settingsFailed = false
    @Published private(set) var validationFailed = false
    @Published private(set) var previewStateFailed = false
    @Published private(set) var experimentalRecords: [ExperimentalKeyboardRecord] = []
    @Published private(set) var previewRecord: SignalPreviewRecord?
    @Published private(set) var quitFailed = false
    @Published private(set) var diagnosticReport: DiagnosticReport
    @Published private(set) var diagnosticReportIsReady = false
    @Published private(set) var diagnosticReportIsRefreshing = false
    @Published private(set) var removalSnapshot = ManagedRemovalSnapshot(status: .reviewRequired)
    @Published var removalIsPresented = false
    @Published private(set) var removalIsWorking = false
    @Published private(set) var removalFailed = false
    @Published var loginLaunchEnabled = true
    @Published private(set) var preferences: AppPreferences

    private let lifecycle: KeyphoreLifecycle
    private let guidedSetup: GuidedSetup?
    private let systemHealth: SystemKeyphoreHealthAdapter?
    private let profileStore: LocalProfileStore?
    private let experimentalStore: ExperimentalKeyboardStore?
    private let previewStore: SignalPreviewStore?
    private let diagnosticSnapshotProvider: (@Sendable () -> DiagnosticSnapshot)?
    private var diagnosticLanguage: AppLanguage
    private var latestDiagnosticSnapshot: DiagnosticSnapshot
    private let preferencesStore: AppPreferencesStore
    private let managedRemoval: ManagedRemoval?
    private let updateRuntime: (any KeyphoreRuntimeManaging)?
    private var durableStatusTimer: Timer?

    init(
        lifecycle: KeyphoreLifecycle,
        guidedSetup: GuidedSetup? = nil,
        systemHealth: SystemKeyphoreHealthAdapter? = nil,
        profileStore: LocalProfileStore? = nil,
        previewStore: SignalPreviewStore? = nil,
        experimentalStore: ExperimentalKeyboardStore? = nil,
        managedRemoval: ManagedRemoval? = nil,
        updateRuntime: (any KeyphoreRuntimeManaging)? = nil,
        diagnosticSnapshotProvider: (@Sendable () -> DiagnosticSnapshot)? = nil,
        diagnosticLanguage: AppLanguage = .english,
        deferSystemStartup: Bool = false,
        startupInspection: @escaping @Sendable () throws -> SystemStartupInspection = SystemStartupInspection.run,
        preferencesStore: AppPreferencesStore = AppPreferencesStore()
    ) {
        self.lifecycle = lifecycle
        self.systemHealth = systemHealth
        self.profileStore = profileStore
        self.previewStore = previewStore
        self.experimentalStore = experimentalStore
        experimentalRecords = (try? experimentalStore?.records()) ?? []
        self.managedRemoval = managedRemoval
        self.updateRuntime = updateRuntime
        self.diagnosticSnapshotProvider = diagnosticSnapshotProvider
        self.diagnosticLanguage = diagnosticLanguage
        self.preferencesStore = preferencesStore
        preferences = preferencesStore.load()
        diagnosticReportIsReady = diagnosticSnapshotProvider == nil
        let initialSnapshot = lifecycle.refresh()
        snapshot = initialSnapshot
        let diagnosticSnapshot = DiagnosticSnapshot(
            appVersion: "Keyphore",
            macOSVersion: "macOS",
            codexHosts: [],
            integration: .notConfigured,
            keyboard: initialSnapshot.keyboardHealth
        )
        latestDiagnosticSnapshot = diagnosticSnapshot
        diagnosticReport = DiagnosticReport(
            snapshot: diagnosticSnapshot,
            language: diagnosticLanguage
        )
        self.guidedSetup = guidedSetup
        setupSnapshot = Self.initialSetupSnapshot(for: initialSnapshot)
        if let profileStore {
            validationFailed = (try? profileStore.load()) == nil
        }
        if let previewStore {
            do {
                previewRecord = try previewStore.load()
            } catch {
                previewStateFailed = true
            }
        }
        if !deferSystemStartup, let guidedSetup, let inspected = try? guidedSetup.inspect() {
            lastSetupInspection = .now
            setupSnapshot = inspected
            systemHealth?.isConfigured = inspected.phase.isConfigured
            if inspected.phase.isConfigured {
                loginLaunchEnabled = guidedSetup.loginLaunchEnabled()
            }
        }
        if !deferSystemStartup, let removal = try? managedRemoval?.inspect() {
            removalSnapshot = removal
            removalIsPresented = removal.status == .repairRequired
        }
        if deferSystemStartup {
            isStarting = true
            startupTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try startupInspection() }
                }.value
                guard let self else { return }
                switch result {
                case .success(let result):
                    self.apply(result.setup)
                    self.lastSetupInspection = .now
                    self.loginLaunchEnabled = result.loginLaunchEnabled
                    self.removalSnapshot = result.removal
                    self.removalIsPresented = result.removal.status == .repairRequired
                case .failure:
                    self.setupFailed = true
                }
                self.snapshot = self.lifecycle.refresh()
                self.isStarting = false
            }
        }
        durableStatusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.refreshDurableStatus()
            }
        }
    }

    convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let fixture = AcceptanceFixture(environment["KEYPHORE_ACCEPTANCE_FIXTURE"])
        let durableStatus: any DurableStatusProviding
        let health: any KeyphoreHealthProviding
        let guidedSetup: GuidedSetup?
        let systemHealth: SystemKeyphoreHealthAdapter?
        let profileStore: LocalProfileStore?
        let previewStore: SignalPreviewStore?
        let profiles: any LocalProfileProviding
        let runtime: any KeyphoreRuntimeManaging
        let diagnosticSnapshotProvider: (@Sendable () -> DiagnosticSnapshot)?
        let managedRemoval: ManagedRemoval?
        if environment["KEYPHORE_ACCEPTANCE_FIXTURE"] == nil {
            durableStatus = SystemDurableStatusAdapter()
            let services = GuidedSetup.systemServices()
            guidedSetup = services.setup
            runtime = services.runtime ?? FixtureRuntimeAdapter()
            managedRemoval = services.removal
            let adapter = SystemKeyphoreHealthAdapter(isConfigured: false)
            systemHealth = adapter
            health = adapter
            let storedProfile = LocalProfileStore(url: KeyphoreRuntimePaths.localProfileURL())
            let storedPreview = SignalPreviewStore(url: KeyphoreRuntimePaths.signalPreviewURL())
            profileStore = storedProfile
            previewStore = storedPreview
            profiles = SystemProfileAdapter(store: storedProfile)
            let appVersion = Self.appVersion()
            let macOSVersion = Self.macOSVersion()
            diagnosticSnapshotProvider = {
                guidedSetup?.diagnosticSnapshot(
                    appVersion: appVersion,
                    macOSVersion: macOSVersion
                ) ?? DiagnosticSnapshot(
                    appVersion: appVersion,
                    macOSVersion: macOSVersion,
                    codexHosts: nil,
                    integration: nil,
                    companion: .unavailable,
                    keyboard: .unavailable,
                )
            }
        } else {
            durableStatus = FixtureDurableStatusAdapter(outcome: fixture.outcome)
            health = FixtureHealthAdapter(health: fixture.health)
            guidedSetup = nil
            systemHealth = nil
            profileStore = nil
            previewStore = nil
            profiles = FixtureProfileAdapter()
            runtime = FixtureRuntimeAdapter()
            managedRemoval = nil
            let appVersion = Self.appVersion()
            let macOSVersion = Self.macOSVersion()
            diagnosticSnapshotProvider = {
                DiagnosticSnapshot(
                    appVersion: appVersion,
                    macOSVersion: macOSVersion,
                    codexHosts: [],
                    integration: .notConfigured,
                    keyboard: fixture.health.keyboard
                )
            }
        }
        let lifecycle = KeyphoreLifecycle(
            health: health,
            profiles: profiles,
            durableStatus: durableStatus,
            lighting: FixtureLightingAdapter(),
            runtime: runtime
        )
        self.init(
            lifecycle: lifecycle,
            guidedSetup: guidedSetup,
            systemHealth: systemHealth,
            profileStore: profileStore,
            previewStore: previewStore,
            experimentalStore: environment["KEYPHORE_ACCEPTANCE_FIXTURE"] == nil ? ExperimentalKeyboardStore() : nil,
            managedRemoval: managedRemoval,
            updateRuntime: runtime,
            diagnosticSnapshotProvider: diagnosticSnapshotProvider,
            diagnosticLanguage: Self.appLanguage(),
            deferSystemStartup: environment["KEYPHORE_ACCEPTANCE_FIXTURE"] == nil
        )
    }

    func refresh() {
        refreshSetupSnapshot()
        snapshot = lifecycle.refresh()
    }

    func refreshDiagnosticReport() {
        guard !diagnosticReportIsRefreshing, let diagnosticSnapshotProvider else { return }
        diagnosticReportIsRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = diagnosticSnapshotProvider()
            DispatchQueue.main.async {
                guard let self else { return }
                self.latestDiagnosticSnapshot = snapshot
                self.diagnosticReport = DiagnosticReport(snapshot: snapshot, language: self.diagnosticLanguage)
                self.diagnosticReportIsReady = true
                self.diagnosticReportIsRefreshing = false
            }
        }
    }

    func configureAfterReview() {
        guard let guidedSetup, !isStarting, !setupIsWorking, !removalIsWorking else { return }
        setupIsWorking = true
        setupFailed = false
        setupHooksChanged = false
        let loginLaunchEnabled = loginLaunchEnabled
        Task {
            do {
                let configured = try await Task.detached {
                    try guidedSetup.configureAfterReview(
                        loginLaunchEnabled: loginLaunchEnabled
                    )
                }.value
                apply(configured)
                lastSetupInspection = .now
                self.loginLaunchEnabled = guidedSetup.loginLaunchEnabled()
                snapshot = lifecycle.refresh()
                refreshDiagnosticReport()
            } catch {
                setupFailed = true
                setupHooksChanged = (error as? GuidedSetupError) == .reviewedHooksChanged
            }
            setupIsWorking = false
        }
    }

    func migrateLegacyAfterReview() {
        guard let guidedSetup, !isStarting, !setupIsWorking, !removalIsWorking else { return }
        setupIsWorking = true
        setupFailed = false
        setupHooksChanged = false
        Task {
            do {
                let configured = try await Task.detached {
                    try guidedSetup.migrateLegacyAfterReview()
                }.value
                apply(configured)
                lastSetupInspection = .now
                snapshot = lifecycle.refresh()
                refreshDiagnosticReport()
            } catch {
                setupFailed = true
                setupHooksChanged = (error as? GuidedSetupError) == .reviewedHooksChanged
                refreshSetupSnapshot()
            }
            setupIsWorking = false
        }
    }

    func waitForStartup() async {
        await startupTask?.value
    }

    func prepareToQuit() -> Bool {
        guard !isStarting, !setupIsWorking, !removalIsWorking else {
            quitFailed = true
            return false
        }
        if removalSnapshot.status == .completed {
            return true
        }
        do {
            try lifecycle.quit()
            quitFailed = false
            return true
        } catch {
            quitFailed = true
            return false
        }
    }

    func prepareForChangedHookUpdate() throws {
        guard let updateRuntime else {
            throw ManagedUpdateRuntimeError.unavailable
        }
        try updateRuntime.activateQuitGate()
        try updateRuntime.disableOwnedHooks()
    }

    func recoverFromFailedChangedHookUpdate() throws {
        guard let updateRuntime else {
            throw ManagedUpdateRuntimeError.unavailable
        }
        guard try updateRuntime.enableOwnedHooksIfTrusted() else {
            throw ManagedUpdateRuntimeError.changedHooks
        }
        try updateRuntime.clearQuitGate()
    }

    func presentManagedRemoval() {
        guard let managedRemoval else { return }
        if let inspected = try? managedRemoval.inspect() {
            removalSnapshot = inspected
        }
        removalIsPresented = true
    }

    func confirmManagedRemoval() {
        guard let managedRemoval, !isStarting, !setupIsWorking, !removalIsWorking else { return }
        removalIsWorking = true
        removalFailed = false
        Task {
            do {
                let removed = try await Task.detached {
                    try managedRemoval.removeAfterConfirmation()
                }.value
                removalSnapshot = removed
            } catch {
                removalFailed = true
                if let inspected = try? managedRemoval.inspect() {
                    removalSnapshot = inspected
                }
            }
            removalIsWorking = false
        }
    }

    var canManageRemoval: Bool { managedRemoval != nil }

    func reopenIfNeeded() throws -> ReopenOutcome? {
        try lifecycle.reopenIfNeeded()
    }

    func updateLoginLaunch(_ enabled: Bool) {
        guard let guidedSetup else { return }
        do {
            try guidedSetup.setLoginLaunchEnabled(enabled)
            loginLaunchEnabled = guidedSetup.loginLaunchEnabled()
            settingsFailed = false
        } catch {
            settingsFailed = true
        }
    }

    func updateAppearance(_ appearance: SignalAppearance, for signal: CodexSignal) {
        save(snapshot.profile.replacingAppearance(appearance, for: signal))
    }

    func resetSignalColor(for signal: CodexSignal) {
        let appearance = snapshot.profile.appearance(for: signal)
        updateAppearance(SignalAppearance(
            isVisible: appearance.isVisible,
            color: LocalProfile.default.appearance(for: signal).color,
            brightness: appearance.brightness,
            pattern: appearance.pattern
        ), for: signal)
    }

    func updatePreferences(_ preferences: AppPreferences) {
        preferencesStore.save(preferences)
        self.preferences = preferences
        diagnosticLanguage = preferences.resolvedLanguage()
        diagnosticReport = DiagnosticReport(snapshot: latestDiagnosticSnapshot, language: diagnosticLanguage)
    }

    func updateCompletionDisplayDuration(_ duration: CompletionDisplayDuration) {
        let profile = snapshot.profile
        save(
            LocalProfile(
                execution: profile.execution,
                attention: profile.attention,
                completion: profile.completion,
                completionDisplayDuration: duration
            )
        )
    }

    var reviewedDiagnosticReport: DiagnosticReport {
        DiagnosticReport(snapshot: latestDiagnosticSnapshot, language: diagnosticLanguage, preview: previewRecord)
    }

    func beginSignalPreview() {
        guard menuState == .ready, let previewStore else { return }
        do {
            previewRecord = try previewStore.begin()
            settingsFailed = false
            previewStateFailed = false
        } catch {
            settingsFailed = true
        }
    }

    func confirmSignalPreview(_ confirmation: VisualConfirmation) {
        guard let previewStore else { return }
        do {
            try previewStore.recordVisualConfirmation(confirmation)
            try guidedSetup?.completeLegacySignalPreview(confirmation)
            previewRecord = try previewStore.load()
            refreshSetupSnapshot(force: true)
            settingsFailed = false
            previewStateFailed = false
        } catch {
            settingsFailed = true
        }
    }

    var currentSignalPresentation: AggregateSignalPresentation {
        snapshot.currentSignal.presentation(in: snapshot.profile)
    }

    var migrationRequiresSignalPreview: Bool {
        if case .awaitingSignalPreview = setupSnapshot.legacyMigrationStatus {
            return true
        }
        return false
    }

    var menuState: MenuState {
        switch setupSnapshot.phase {
        case .codexHostMissing, .legacyMigrationReview, .legacyMigrationRepair, .hookReview:
            .configurationRequired
        case .configured, .ready: snapshot.menuState
        }
    }

    func refreshDurableStatus(at now: ContinuousClock.Instant = .now) {
        guard !isStarting else { return }
        if setupSnapshot.phase.isConfigured {
            refreshSetupSnapshot(at: now)
        }
        snapshot = lifecycle.refresh()
        refreshStoredState()
    }

    func waitForSetupInspection() async {
        await inspectionTask?.value
    }

    private func refreshSetupSnapshot(at now: ContinuousClock.Instant = .now, force: Bool = false) {
        guard !isStarting, !inspectionIsRunning, !setupIsWorking, !removalIsWorking,
              let guidedSetup else { return }
        if !force, let lastSetupInspection, lastSetupInspection.duration(to: now) < .seconds(60) {
            return
        }
        lastSetupInspection = now
        inspectionIsRunning = true
        inspectionTask = Task { [weak self] in
            let inspected = await Task.detached { try? guidedSetup.inspect() }.value
            guard let self else { return }
            if !self.setupIsWorking, !self.removalIsWorking, let inspected { self.apply(inspected) }
            self.inspectionIsRunning = false
        }
    }

    private func apply(_ inspected: GuidedSetupSnapshot) {
        setupSnapshot = inspected
        systemHealth?.isConfigured = inspected.phase.isConfigured
    }

    private func save(_ profile: LocalProfile) {
        guard let profileStore else { return }
        do {
            try profileStore.save(profile)
            snapshot = lifecycle.refresh()
            settingsFailed = false
            validationFailed = false
        } catch {
            settingsFailed = true
        }
    }

    func updateExperimental(_ identity: ExperimentalKeyboardIdentity, action: String) {
        guard let experimentalStore else { return }
        do {
            switch action {
            case "start": try experimentalStore.requestTrial(identity)
            case "confirm": try experimentalStore.confirm(identity)
            default: try experimentalStore.revoke(identity)
            }
            experimentalRecords = try experimentalStore.records()
            settingsFailed = false
        } catch { settingsFailed = true }
    }

    private func refreshStoredState() {
        do { experimentalRecords = try experimentalStore?.records() ?? [] }
        catch { settingsFailed = true; experimentalRecords = [] }
        if let profileStore {
            do {
                _ = try profileStore.load()
                validationFailed = false
            } catch {
                validationFailed = true
            }
        }
        if let previewStore {
            do {
                previewRecord = try previewStore.load()
                previewStateFailed = false
            } catch {
                previewStateFailed = true
            }
        }
    }

    private static func appVersion(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private static func macOSVersion(
        processInfo: ProcessInfo = .processInfo
    ) -> String {
        let version = processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func appLanguage() -> AppLanguage {
        AppPreferencesStore().load().resolvedLanguage()
    }

    private static func initialSetupSnapshot(for snapshot: LifecycleSnapshot) -> GuidedSetupSnapshot {
        let phase: GuidedSetupPhase
        switch snapshot.menuState {
        case .configurationRequired: phase = .hookReview
        case .configured: phase = .configured
        case .ready: phase = .ready
        }
        return GuidedSetupSnapshot(
            phase: phase,
            detectedHosts: [],
            hooks: HookDefinition.reviewedRelease
        )
    }
}

private enum ManagedUpdateRuntimeError: Error {
    case unavailable
    case changedHooks
}

private struct AcceptanceFixture {
    let health: KeyphoreHealth
    let outcome: DurableStatusOutcome

    init(_ name: String?) {
        switch name {
        case "configured":
            health = .configured(keyboard: .disconnected)
            outcome = .signalOff
        case "ready-execution":
            health = .configured(keyboard: .connected(protocolHealthy: true))
            outcome = .execution
        case "ready-attention":
            health = .configured(keyboard: .connected(protocolHealthy: true))
            outcome = .attention
        case "ready-completion":
            health = .configured(keyboard: .connected(protocolHealthy: true))
            outcome = .completion
        case "ready-off":
            health = .configured(keyboard: .connected(protocolHealthy: true))
            outcome = .signalOff
        default:
            health = .configurationRequired
            outcome = .signalOff
        }
    }
}

private struct FixtureHealthAdapter: KeyphoreHealthProviding {
    let health: KeyphoreHealth
    func currentHealth() -> KeyphoreHealth { health }
}

private struct FixtureProfileAdapter: LocalProfileProviding {
    func currentProfile() -> LocalProfile { .default }
}

private struct SystemProfileAdapter: LocalProfileProviding {
    let store: LocalProfileStore

    func currentProfile() -> LocalProfile {
        (try? store.load()) ?? .default
    }
}

private struct FixtureDurableStatusAdapter: DurableStatusProviding {
    let outcome: DurableStatusOutcome
    func currentOutcome() -> DurableStatusOutcome { outcome }
}

private struct SystemDurableStatusAdapter: DurableStatusProviding {
    private let store = DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL())

    func currentOutcome() -> DurableStatusOutcome {
        (try? store.outcome(at: .now)) ?? .signalOff
    }
}

final class SystemKeyphoreHealthAdapter: KeyphoreHealthProviding {
    var isConfigured: Bool
    private let keyboardHealth = KeyboardHealthStore(url: KeyphoreRuntimePaths.keyboardHealthURL())

    init(isConfigured: Bool) {
        self.isConfigured = isConfigured
    }

    func currentHealth() -> KeyphoreHealth {
        KeyphoreHealth(
            isConfigured: isConfigured,
            keyboard: keyboardHealth.load()
        )
    }
}

private extension GuidedSetupPhase {
    var isConfigured: Bool {
        self == .configured || self == .ready
    }
}

private final class FixtureLightingAdapter: LightingEmitting {
    func emit(_ behavior: LightingBehavior) {}
}

private final class FixtureRuntimeAdapter: KeyphoreRuntimeManaging {
    func activateQuitGate() {}
    func disableOwnedHooks() {}
    func stopCompanion() {}
    func clearManagedRuntimeState() {}
    func requestSignalOff() {}
    func enableOwnedHooksIfTrusted() -> Bool { true }
    func startCompanion() {}
    func clearQuitGate() {}
}
