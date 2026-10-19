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
    @Published private(set) var desiredKeyboardModel: SupportedKeyboardModel?
    @Published private(set) var keyboardSelectionSnapshot: KeyboardSelectionSnapshot?
    @Published private(set) var keyboardSelectionFailed = false
    @Published private(set) var profileModel: SupportedKeyboardModel?
    @Published private(set) var previewRecord: SignalPreviewRecord?
    @Published private(set) var quitFailed = false
    @Published private(set) var diagnosticReport: DiagnosticReport
    @Published private(set) var diagnosticReportIsReady = false
    @Published private(set) var diagnosticReportIsRefreshing = false
    @Published private(set) var removalSnapshot = ManagedRemovalSnapshot(status: .reviewRequired)
    @Published var removalIsPresented = false
    @Published private(set) var removalIsWorking = false
    @Published private(set) var removalFailed = false
    @Published private(set) var agentSourceSnapshots: [AgentSourceSnapshot] = []
    @Published private(set) var agentIntegrationReview: AgentIntegrationReview?
    @Published private(set) var agentIntegrationWorkingSource: AgentSource?
    @Published private(set) var agentIntegrationFailedSources: Set<AgentSource> = []
    @Published var agentRemovalSource: AgentSource?
    @Published var loginLaunchEnabled = true
    @Published private(set) var preferences: AppPreferences

    private let lifecycle: KeyphoreLifecycle
    private let guidedSetup: GuidedSetup?
    private let systemHealth: SystemKeyphoreHealthAdapter?
    private let keyboardProfileStore: KeyboardProfileStore?
    private let experimentalStore: ExperimentalKeyboardStore?
    private let keyboardSelectionStore: KeyboardSelectionStore?
    private let keyboardSelectionSnapshotStore: KeyboardSelectionSnapshotStore?
    private let previewStore: SignalPreviewStore?
    private let diagnosticSnapshotProvider: (@Sendable () -> DiagnosticSnapshot)?
    private var diagnosticLanguage: AppLanguage
    private var latestDiagnosticSnapshot: DiagnosticSnapshot
    private let preferencesStore: AppPreferencesStore
    private let managedRemoval: ManagedRemoval?
    private let agentIntegrations: SystemAgentIntegrations?
    private let updateRuntime: (any KeyphoreRuntimeManaging)?
    private var durableStatusTimer: Timer?
    private var agentIntegrationTask: Task<Void, Never>?
    private var agentSnapshotRefreshTask: Task<Void, Never>?
    private var agentSnapshotGeneration: UInt64 = 0

    init(
        lifecycle: KeyphoreLifecycle,
        guidedSetup: GuidedSetup? = nil,
        systemHealth: SystemKeyphoreHealthAdapter? = nil,
        keyboardProfileStore: KeyboardProfileStore? = nil,
        previewStore: SignalPreviewStore? = nil,
        experimentalStore: ExperimentalKeyboardStore? = nil,
        keyboardSelectionStore: KeyboardSelectionStore? = nil,
        keyboardSelectionSnapshotStore: KeyboardSelectionSnapshotStore? = nil,
        managedRemoval: ManagedRemoval? = nil,
        agentIntegrations: SystemAgentIntegrations? = nil,
        updateRuntime: (any KeyphoreRuntimeManaging)? = nil,
        diagnosticSnapshotProvider: (@Sendable () -> DiagnosticSnapshot)? = nil,
        diagnosticLanguage: AppLanguage = .english,
        deferSystemStartup: Bool = false,
        startupInspection: @escaping @Sendable () throws -> SystemStartupInspection = SystemStartupInspection.run,
        preferencesStore: AppPreferencesStore = AppPreferencesStore()
    ) {
        self.lifecycle = lifecycle
        self.systemHealth = systemHealth
        self.keyboardProfileStore = keyboardProfileStore
        profileModel = nil
        self.previewStore = previewStore
        self.experimentalStore = experimentalStore
        experimentalRecords = (try? experimentalStore?.records()) ?? []
        self.keyboardSelectionStore = keyboardSelectionStore
        self.keyboardSelectionSnapshotStore = keyboardSelectionSnapshotStore
        if let keyboardSelectionStore {
            do { desiredKeyboardModel = try keyboardSelectionStore.load() }
            catch { desiredKeyboardModel = nil; keyboardSelectionFailed = true }
        } else {
            desiredKeyboardModel = nil
        }
        keyboardSelectionSnapshot = keyboardSelectionSnapshotStore?.load()
        self.managedRemoval = managedRemoval
        self.agentIntegrations = agentIntegrations
        self.updateRuntime = updateRuntime
        self.diagnosticSnapshotProvider = diagnosticSnapshotProvider
        self.diagnosticLanguage = diagnosticLanguage
        self.preferencesStore = preferencesStore
        preferences = preferencesStore.load()
        diagnosticReportIsReady = diagnosticSnapshotProvider == nil
        let initialAgentSnapshots = (try? agentIntegrations?.localSnapshots()) ?? []
        if initialAgentSnapshots.contains(where: { $0.source != .codex && $0.approved }) {
            systemHealth?.isConfigured = true
        }
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
        agentSourceSnapshots = initialAgentSnapshots
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
            systemHealth?.isConfigured = inspected.phase.isConfigured || hasReadyAgentSource
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
                self.refreshKeyboardSelection()
                self.refreshLifecycleSnapshot()
                self.isStarting = false
                self.refreshAgentIntegrations()
            }
        } else {
            refreshAgentIntegrations()
        }
        refreshLifecycleSnapshot()
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
        let keyboardProfileStore: KeyboardProfileStore?
        let keyboardSelectionStore: KeyboardSelectionStore?
        let keyboardSelectionSnapshotStore: KeyboardSelectionSnapshotStore?
        let previewStore: SignalPreviewStore?
        let profiles: any LocalProfileProviding
        let runtime: any KeyphoreRuntimeManaging
        let diagnosticSnapshotProvider: (@Sendable () -> DiagnosticSnapshot)?
        let managedRemoval: ManagedRemoval?
        let agentIntegrations: SystemAgentIntegrations?
        if environment["KEYPHORE_ACCEPTANCE_FIXTURE"] == nil {
            durableStatus = SystemDurableStatusAdapter()
            let services = GuidedSetup.systemServices()
            guidedSetup = services.setup
            runtime = services.runtime ?? FixtureRuntimeAdapter()
            managedRemoval = services.removal
            agentIntegrations = services.integrations
            let adapter = SystemKeyphoreHealthAdapter(isConfigured: false)
            systemHealth = adapter
            health = adapter
            let storedProfiles = KeyboardProfileStore(directory: KeyphoreRuntimePaths.keyboardProfilesDirectory())
            let storedSelection = KeyboardSelectionStore(url: KeyphoreRuntimePaths.keyboardSelectionURL())
            let storedSelectionSnapshot = KeyboardSelectionSnapshotStore(
                url: KeyphoreRuntimePaths.keyboardSelectionSnapshotURL()
            )
            let storedPreview = SignalPreviewStore(url: KeyphoreRuntimePaths.signalPreviewURL())
            keyboardProfileStore = storedProfiles
            keyboardSelectionStore = storedSelection
            keyboardSelectionSnapshotStore = storedSelectionSnapshot
            previewStore = storedPreview
            profiles = FixtureProfileAdapter()
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
            keyboardProfileStore = nil
            keyboardSelectionStore = nil
            keyboardSelectionSnapshotStore = nil
            previewStore = nil
            profiles = FixtureProfileAdapter()
            runtime = FixtureRuntimeAdapter()
            managedRemoval = nil
            agentIntegrations = nil
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
            keyboardProfileStore: keyboardProfileStore,
            previewStore: previewStore,
            experimentalStore: environment["KEYPHORE_ACCEPTANCE_FIXTURE"] == nil ? ExperimentalKeyboardStore() : nil,
            keyboardSelectionStore: keyboardSelectionStore,
            keyboardSelectionSnapshotStore: keyboardSelectionSnapshotStore,
            managedRemoval: managedRemoval,
            agentIntegrations: agentIntegrations,
            updateRuntime: runtime,
            diagnosticSnapshotProvider: diagnosticSnapshotProvider,
            diagnosticLanguage: Self.appLanguage(),
            deferSystemStartup: environment["KEYPHORE_ACCEPTANCE_FIXTURE"] == nil
        )
    }

    func refresh() {
        refreshSetupSnapshot()
        refreshAgentIntegrations()
        refreshKeyboardSelection()
        refreshLifecycleSnapshot()
    }

    var canSelectKeyboard: Bool { keyboardSelectionStore != nil }

    var keyboardSelectionOptions: [KeyboardTargetOption] {
        keyboardTargetOptions(desired: desiredKeyboardModel, snapshot: keyboardSelectionSnapshot)
    }

    var keyboardSelectionMessageKey: AppCopyKey? {
        keyboardSelectionStatusKey(desired: desiredKeyboardModel, snapshot: keyboardSelectionSnapshot,
                                   failed: keyboardSelectionFailed)
    }

    var keyboardSelectionActiveLabel: String {
        keyboardSelectionSnapshot?.activeModel?.rawValue ?? AppCopy.value(.keyboardSelectionNone)
    }

    func keyboardTargetLabel(_ option: KeyboardTargetOption) -> String {
        guard let model = option.model else { return AppCopy.value(.keyboardSelectionAutomatic) }
        guard option.connectedCount > 0 else {
            return "\(model.rawValue) · \(AppCopy.value(.keyboardSelectionDisconnected))"
        }
        return "\(model.rawValue) · " + String(format: AppCopy.value(.keyboardSelectionConnectedCount), option.connectedCount)
    }

    func canRequestKeyboardSelection(_ model: SupportedKeyboardModel?) -> Bool {
        guard keyboardSelectionStore != nil, !isStarting, !setupIsWorking, !removalIsWorking,
              agentIntegrationWorkingSource == nil, removalSnapshot.status != .completed,
              let fresh = keyboardSelectionSnapshotStore?.load(), !fresh.inventory.isEmpty else { return false }
        if let model {
            return SupportedKeyboardModel.selectableModels.contains(model)
                && fresh.inventory.first { $0.model == model }?.count == 1
        }
        return fresh.inventory.contains { $0.count > 0 }
    }

    var activeKeyboardModel: SupportedKeyboardModel? {
        if let keyboardSelectionSnapshot { return keyboardSelectionSnapshot.activeModel }
        return snapshot.keyboardHealth.model
    }

    var keyboardSelectionAllowsPreview: Bool {
        guard keyboardSelectionStore != nil else { return true }
        guard keyboardSelectionIsApplied, let keyboardSelectionSnapshot,
              let fresh = keyboardSelectionSnapshotStore?.load(), fresh.phase == .applied,
              fresh.activeModel == keyboardSelectionSnapshot.activeModel,
              fresh.desiredModel == keyboardSelectionSnapshot.desiredModel,
              let activeModel = fresh.activeModel else { return false }
        do {
            guard try keyboardSelectionStore?.load() == fresh.desiredModel else { return false }
        } catch { return false }
        return snapshot.keyboardHealth.isProtocolHealthy
            && snapshot.keyboardHealth.model == activeModel
    }

    var canPreviewLighting: Bool {
        previewStore != nil && !isStarting && !setupIsWorking && !removalIsWorking
            && agentIntegrationWorkingSource == nil && !quitFailed
            && removalSnapshot.status != .completed
            && snapshot.keyboardHealth.isProtocolHealthy && keyboardSelectionAllowsPreview
    }

    var keyboardSelectionIsApplied: Bool {
        guard keyboardSelectionStore != nil else { return true }
        guard !keyboardSelectionFailed, let keyboardSelectionSnapshot else { return false }
        return desiredKeyboardModel == keyboardSelectionSnapshot.desiredModel
            && keyboardSelectionSnapshot.phase == .applied
            && keyboardSelectionSnapshot.activeModel != nil
    }

    var keyboardProfileAllowsEditing: Bool {
        guard keyboardProfileStore != nil else { return true }
        guard keyboardSelectionIsApplied, let keyboardSelectionSnapshot else { return false }
        return profileModel == keyboardSelectionSnapshot.activeModel && profileModel != nil
    }

    @discardableResult
    func requestKeyboardSelection(_ model: SupportedKeyboardModel?) -> Bool {
        // A menu can outlive a USB topology change. Revalidate at the action boundary.
        refreshKeyboardSelection()
        guard let keyboardSelectionStore, canRequestKeyboardSelection(model) else {
            keyboardSelectionFailed = true
            return false
        }
        do {
            try keyboardSelectionStore.save(model)
            desiredKeyboardModel = model
            keyboardSelectionFailed = false
            return true
        } catch {
            keyboardSelectionFailed = true
            return false
        }
    }

    func refreshKeyboardSelection() {
        guard let keyboardSelectionStore else { return }
        do {
            desiredKeyboardModel = try keyboardSelectionStore.load()
            keyboardSelectionFailed = false
        } catch {
            keyboardSelectionFailed = true
        }
        keyboardSelectionSnapshot = keyboardSelectionSnapshotStore?.load()
    }

    var canManageAgentIntegrations: Bool { agentIntegrations != nil }

    var hasReadyAgentSource: Bool {
        agentSourceSnapshots.contains { $0.source != .codex && $0.approved }
    }

    func refreshAgentIntegrations() {
        guard let agentIntegrations, agentIntegrationWorkingSource == nil,
              !isStarting, !setupIsWorking, !removalIsWorking else { return }
        let generation = nextAgentSnapshotGeneration()
        agentSnapshotRefreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try agentIntegrations.snapshots() }
            }.value
            guard let self else { return }
            if case .success(let snapshots) = result, generation == self.agentSnapshotGeneration {
                self.applyAgentSnapshots(snapshots)
            }
        }
    }

    func reviewAgentIntegration(_ source: AgentSource) {
        guard source != .codex, let agentIntegrations,
              agentIntegrationWorkingSource == nil,
              !isStarting, !setupIsWorking, !removalIsWorking else { return }
        agentIntegrationWorkingSource = source
        agentIntegrationFailedSources.remove(source)
        agentIntegrationTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try agentIntegrations.review(source) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let review): self.agentIntegrationReview = review
            case .failure: self.agentIntegrationFailedSources.insert(source)
            }
            self.agentIntegrationWorkingSource = nil
        }
    }

    func installReviewedAgentIntegration() {
        guard let review = agentIntegrationReview, let agentIntegrations,
              agentIntegrationWorkingSource == nil,
              !isStarting, !setupIsWorking, !removalIsWorking else { return }
        let source = review.source
        let generation = nextAgentSnapshotGeneration()
        agentIntegrationWorkingSource = source
        agentIntegrationFailedSources.remove(source)
        agentIntegrationTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (Bool, [AgentSourceSnapshot]?) in
                do {
                    try agentIntegrations.install(source, reviewedDigest: review.digest)
                    return (true, (try? agentIntegrations.snapshots()) ?? (try? agentIntegrations.localSnapshots()))
                } catch {
                    return (false, nil)
                }
            }.value
            guard let self else { return }
            if result.0 {
                self.agentIntegrationReview = nil
                if generation == self.agentSnapshotGeneration, let snapshots = result.1 {
                    self.applyAgentSnapshots(snapshots)
                }
            } else {
                self.agentIntegrationFailedSources.insert(source)
            }
            self.agentIntegrationWorkingSource = nil
        }
    }

    func requestAgentIntegrationRemoval(_ source: AgentSource) {
        guard source != .codex else { return }
        agentRemovalSource = source
    }

    func cancelAgentIntegrationRemoval() {
        agentRemovalSource = nil
    }

    func confirmAgentIntegrationRemoval() {
        guard let source = agentRemovalSource, let agentIntegrations,
              agentIntegrationWorkingSource == nil,
              !isStarting, !setupIsWorking, !removalIsWorking else { return }
        agentRemovalSource = nil
        let generation = nextAgentSnapshotGeneration()
        agentIntegrationWorkingSource = source
        agentIntegrationFailedSources.remove(source)
        agentIntegrationTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (Bool, [AgentSourceSnapshot]?) in
                do {
                    try agentIntegrations.remove(source)
                    return (true, (try? agentIntegrations.snapshots()) ?? (try? agentIntegrations.localSnapshots()))
                } catch {
                    return (false, nil)
                }
            }.value
            guard let self else { return }
            if result.0 {
                if self.agentIntegrationReview?.source == source { self.agentIntegrationReview = nil }
                if generation == self.agentSnapshotGeneration, let snapshots = result.1 {
                    self.applyAgentSnapshots(snapshots)
                }
            } else {
                self.agentIntegrationFailedSources.insert(source)
            }
            self.agentIntegrationWorkingSource = nil
        }
    }

    func waitForAgentIntegrationOperation() async {
        await agentIntegrationTask?.value
    }

    func waitForAgentSnapshotRefresh() async {
        await agentSnapshotRefreshTask?.value
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
        guard let guidedSetup, !isStarting, !setupIsWorking, !removalIsWorking,
              agentIntegrationWorkingSource == nil else { return }
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
                refreshKeyboardSelection()
                refreshLifecycleSnapshot()
                refreshDiagnosticReport()
            } catch {
                setupFailed = true
                setupHooksChanged = (error as? GuidedSetupError) == .reviewedHooksChanged
            }
            setupIsWorking = false
        }
    }

    func migrateLegacyAfterReview() {
        guard let guidedSetup, !isStarting, !setupIsWorking, !removalIsWorking,
              agentIntegrationWorkingSource == nil else { return }
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
                refreshKeyboardSelection()
                refreshLifecycleSnapshot()
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
        guard !isStarting, !setupIsWorking, !removalIsWorking,
              agentIntegrationWorkingSource == nil else {
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
        guard let managedRemoval, !isStarting, !setupIsWorking, !removalIsWorking,
              agentIntegrationWorkingSource == nil else { return }
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

    func updateAppearance(
        _ appearance: SignalAppearance, for signal: CodexSignal,
        expectedModel: SupportedKeyboardModel
    ) {
        let preset: LightingPreset = switch signal {
        case .execution: .execution
        case .attention: .attention
        case .completion: .completion
        }
        updateAppearance(appearance, for: preset, expectedModel: expectedModel)
    }

    func updateAppearance(
        _ appearance: SignalAppearance, for preset: LightingPreset,
        expectedModel: SupportedKeyboardModel
    ) {
        if save(snapshot.profile.replacingAppearance(appearance, forPreset: preset), expectedModel: expectedModel) {
            beginSignalPreview(for: preset, expectedModel: expectedModel)
        }
    }

    func resetSignalColor(
        for signal: CodexSignal, zone: LightingZone,
        expectedModel: SupportedKeyboardModel
    ) {
        let appearance = snapshot.profile.appearance(for: signal)
        let currentZone = appearance.appearance(for: zone)
        let defaultColor = LocalProfile.default.appearance(for: signal).appearance(for: zone).color
        updateAppearance(appearance.replacingAppearance(ZoneAppearance(
            effect: currentZone.effect, color: defaultColor, colorMode: .custom,
            brightness: currentZone.brightness, speed: currentZone.speed, direction: currentZone.direction
        ), for: zone), for: signal, expectedModel: expectedModel)
    }

    @discardableResult
    func updateControlledZones(
        _ zones: ControlledZones, expectedModel: SupportedKeyboardModel
    ) -> Bool {
        save(snapshot.profile.replacingControlledZones(zones), expectedModel: expectedModel)
    }

    func updatePreferences(_ preferences: AppPreferences) {
        preferencesStore.save(preferences)
        self.preferences = preferences
        diagnosticLanguage = preferences.resolvedLanguage()
        diagnosticReport = DiagnosticReport(snapshot: latestDiagnosticSnapshot, language: diagnosticLanguage)
    }

    func updateCompletionDisplayDuration(
        _ duration: CompletionDisplayDuration, expectedModel: SupportedKeyboardModel
    ) {
        let profile = snapshot.profile
        save(
            LocalProfile(
                execution: profile.execution,
                attention: profile.attention,
                completion: profile.completion,
                idle: profile.idle,
                completionDisplayDuration: duration,
                controlledZones: profile.controlledZones
            ),
            expectedModel: expectedModel
        )
    }

    var reviewedDiagnosticReport: DiagnosticReport {
        DiagnosticReport(snapshot: latestDiagnosticSnapshot, language: diagnosticLanguage, preview: previewRecord)
    }

    func beginSignalPreview(for preset: LightingPreset? = nil, expectedModel: SupportedKeyboardModel? = nil) {
        guard !isStarting else { return }
        // Physical verification depends on the current Companion and target, not Agent setup.
        refreshKeyboardSelection()
        refreshLifecycleSnapshot()
        guard canPreviewLighting, let previewStore else { return }
        let targetModel = keyboardSelectionStore == nil
            ? snapshot.keyboardHealth.model
            : keyboardSelectionSnapshot?.activeModel
        guard expectedModel == nil || targetModel == expectedModel else { return }
        do {
            previewRecord = try previewStore.begin(preset: preset, targetModel: targetModel)
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
        case .codexHostMissing where hasReadyAgentSource:
            snapshot.menuState
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
        refreshKeyboardSelection()
        refreshLifecycleSnapshot()
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
        systemHealth?.isConfigured = inspected.phase.isConfigured || hasReadyAgentSource
    }

    private func applyAgentSnapshots(_ snapshots: [AgentSourceSnapshot]) {
        agentSourceSnapshots = snapshots
        systemHealth?.isConfigured = setupSnapshot.phase.isConfigured || hasReadyAgentSource
        refreshKeyboardSelection()
        refreshLifecycleSnapshot()
        refreshDiagnosticReport()
    }

    private func nextAgentSnapshotGeneration() -> UInt64 {
        agentSnapshotGeneration &+= 1
        return agentSnapshotGeneration
    }

    @discardableResult
    private func save(_ profile: LocalProfile, expectedModel: SupportedKeyboardModel) -> Bool {
        do {
            guard let keyboardProfileStore, let keyboardSelectionStore,
                  let fresh = keyboardSelectionSnapshotStore?.load(), fresh.phase == .applied,
                  fresh.activeModel == expectedModel, profileModel == expectedModel,
                  try keyboardSelectionStore.load() == fresh.desiredModel else {
                settingsFailed = true
                return false
            }
            try keyboardProfileStore.save(profile, for: expectedModel)
            refreshLifecycleSnapshot()
            settingsFailed = false
            validationFailed = false
            return true
        } catch {
            settingsFailed = true
            return false
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
        if let previewStore {
            do {
                previewRecord = try previewStore.load()
                previewStateFailed = false
            } catch {
                previewStateFailed = true
            }
        }
    }

    private func refreshLifecycleSnapshot() {
        let refreshed = lifecycle.refresh()
        guard let keyboardProfileStore else {
            snapshot = refreshed
            return
        }
        guard !keyboardSelectionFailed, let selection = keyboardSelectionSnapshot,
              desiredKeyboardModel == selection.desiredModel,
              selection.phase == .applied, let model = selection.activeModel else {
            profileModel = nil
            snapshot = LifecycleSnapshot(
                health: refreshed.health, menuState: refreshed.menuState,
                durableStatus: refreshed.durableStatus, currentSignal: .signalOff,
                profile: .default
            )
            return
        }
        do {
            let profile = try keyboardProfileStore.load(for: model)
            profileModel = model
            validationFailed = false
            snapshot = LifecycleSnapshot(
                health: refreshed.health, menuState: refreshed.menuState,
                durableStatus: refreshed.durableStatus,
                currentSignal: profile.aggregateSignal(for: refreshed.durableStatus),
                profile: profile
            )
        } catch {
            profileModel = model
            validationFailed = true
            snapshot = LifecycleSnapshot(
                health: refreshed.health, menuState: refreshed.menuState,
                durableStatus: refreshed.durableStatus, currentSignal: .signalOff,
                profile: .default
            )
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
    private let keyboardHealth: KeyboardHealthStore

    init(isConfigured: Bool, keyboardHealth: KeyboardHealthStore = KeyboardHealthStore(url: KeyphoreRuntimePaths.keyboardHealthURL())) {
        self.isConfigured = isConfigured
        self.keyboardHealth = keyboardHealth
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
