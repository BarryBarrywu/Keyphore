import Foundation
import KeyphoreCore

@MainActor
final class KeyphoreAppState: ObservableObject {
    @Published private(set) var snapshot: LifecycleSnapshot
    @Published private(set) var setupSnapshot: GuidedSetupSnapshot
    @Published private(set) var setupFailed = false
    @Published private(set) var setupHooksChanged = false
    @Published private(set) var setupIsWorking = false
    @Published private(set) var settingsFailed = false
    @Published private(set) var validationFailed = false
    @Published private(set) var previewStateFailed = false
    @Published private(set) var previewRecord: SignalPreviewRecord?

    private let lifecycle: KeyphoreLifecycle
    private let guidedSetup: GuidedSetup?
    private let systemHealth: SystemKeyphoreHealthAdapter?
    private let profileStore: LocalProfileStore?
    private let previewStore: SignalPreviewStore?
    private var durableStatusTimer: Timer?

    private init(
        lifecycle: KeyphoreLifecycle,
        guidedSetup: GuidedSetup? = nil,
        systemHealth: SystemKeyphoreHealthAdapter? = nil,
        profileStore: LocalProfileStore? = nil,
        previewStore: SignalPreviewStore? = nil
    ) {
        self.lifecycle = lifecycle
        self.systemHealth = systemHealth
        self.profileStore = profileStore
        self.previewStore = previewStore
        let initialSnapshot = lifecycle.refresh()
        snapshot = initialSnapshot
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
        if let guidedSetup, let inspected = try? guidedSetup.inspect() {
            setupSnapshot = inspected
            systemHealth?.isConfigured = inspected.phase.isConfigured
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
        if environment["KEYPHORE_ACCEPTANCE_FIXTURE"] == nil {
            durableStatus = SystemDurableStatusAdapter()
            guidedSetup = .system()
            let configured = guidedSetup.flatMap { try? $0.inspect() }?.phase.isConfigured ?? false
            let adapter = SystemKeyphoreHealthAdapter(isConfigured: configured)
            systemHealth = adapter
            health = adapter
            let storedProfile = LocalProfileStore(url: KeyphoreRuntimePaths.localProfileURL())
            let storedPreview = SignalPreviewStore(url: KeyphoreRuntimePaths.signalPreviewURL())
            profileStore = storedProfile
            previewStore = storedPreview
            profiles = SystemProfileAdapter(store: storedProfile)
        } else {
            durableStatus = FixtureDurableStatusAdapter(outcome: fixture.outcome)
            health = FixtureHealthAdapter(health: fixture.health)
            guidedSetup = nil
            systemHealth = nil
            profileStore = nil
            previewStore = nil
            profiles = FixtureProfileAdapter()
        }
        let lifecycle = KeyphoreLifecycle(
            health: health,
            profiles: profiles,
            durableStatus: durableStatus,
            lighting: FixtureLightingAdapter(),
            runtime: FixtureRuntimeAdapter()
        )
        self.init(
            lifecycle: lifecycle,
            guidedSetup: guidedSetup,
            systemHealth: systemHealth,
            profileStore: profileStore,
            previewStore: previewStore
        )
    }

    func refresh() {
        refreshSetupSnapshot()
        snapshot = lifecycle.refresh()
    }

    func configureAfterReview() {
        guard let guidedSetup, !setupIsWorking else { return }
        setupIsWorking = true
        setupFailed = false
        setupHooksChanged = false
        Task {
            do {
                let configured = try await Task.detached {
                    try guidedSetup.configureAfterReview()
                }.value
                apply(configured)
                snapshot = lifecycle.refresh()
            } catch {
                setupFailed = true
                setupHooksChanged = (error as? GuidedSetupError) == .reviewedHooksChanged
            }
            setupIsWorking = false
        }
    }

    func prepareToQuit() {
        lifecycle.quit()
    }

    func updateAppearance(_ appearance: SignalAppearance, for signal: CodexSignal) {
        save(snapshot.profile.replacingAppearance(appearance, for: signal))
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
            previewRecord = try previewStore.load()
            settingsFailed = false
            previewStateFailed = false
        } catch {
            settingsFailed = true
        }
    }

    var menuBarSymbol: String {
        currentSignalPresentation.systemImage
    }

    var currentSignalPresentation: AggregateSignalPresentation {
        snapshot.currentSignal.presentation(in: snapshot.profile)
    }

    var menuState: MenuState {
        switch setupSnapshot.phase {
        case .codexHostMissing, .hookReview: .configurationRequired
        case .configured, .ready: snapshot.menuState
        }
    }

    private func refreshDurableStatus() {
        if setupSnapshot.phase.isConfigured {
            refreshSetupSnapshot()
        }
        snapshot = lifecycle.refresh()
        refreshStoredState()
    }

    private func refreshSetupSnapshot() {
        guard let guidedSetup, let inspected = try? guidedSetup.inspect() else { return }
        apply(inspected)
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

    private func refreshStoredState() {
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

private final class SystemKeyphoreHealthAdapter: KeyphoreHealthProviding {
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
    func disableOwnedHooks() {}
    func stopCompanion() {}
    func clearManagedRuntimeState() {}
}
