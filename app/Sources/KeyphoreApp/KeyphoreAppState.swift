import Foundation
import KeyphoreCore

@MainActor
final class KeyphoreAppState: ObservableObject {
    @Published private(set) var snapshot: LifecycleSnapshot
    @Published private(set) var setupSnapshot: GuidedSetupSnapshot
    @Published private(set) var setupFailed = false
    @Published private(set) var setupHooksChanged = false
    @Published private(set) var setupIsWorking = false

    private let lifecycle: KeyphoreLifecycle
    private let guidedSetup: GuidedSetup?
    private let systemHealth: SystemKeyphoreHealthAdapter?
    private var durableStatusTimer: Timer?

    private init(
        lifecycle: KeyphoreLifecycle,
        guidedSetup: GuidedSetup? = nil,
        systemHealth: SystemKeyphoreHealthAdapter? = nil
    ) {
        self.lifecycle = lifecycle
        self.systemHealth = systemHealth
        let initialSnapshot = lifecycle.refresh()
        snapshot = initialSnapshot
        self.guidedSetup = guidedSetup
        setupSnapshot = Self.initialSetupSnapshot(for: initialSnapshot)
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
        if environment["KEYPHORE_ACCEPTANCE_FIXTURE"] == nil {
            durableStatus = SystemDurableStatusAdapter()
            guidedSetup = .system()
            let configured = guidedSetup.flatMap { try? $0.inspect() }?.phase.isConfigured ?? false
            let adapter = SystemKeyphoreHealthAdapter(isConfigured: configured)
            systemHealth = adapter
            health = adapter
        } else {
            durableStatus = FixtureDurableStatusAdapter(outcome: fixture.outcome)
            health = FixtureHealthAdapter(health: fixture.health)
            guidedSetup = nil
            systemHealth = nil
        }
        let lifecycle = KeyphoreLifecycle(
            health: health,
            profiles: FixtureProfileAdapter(),
            durableStatus: durableStatus,
            lighting: FixtureLightingAdapter(),
            runtime: FixtureRuntimeAdapter()
        )
        self.init(
            lifecycle: lifecycle,
            guidedSetup: guidedSetup,
            systemHealth: systemHealth
        )
    }

    func refresh() {
        if let guidedSetup, let inspected = try? guidedSetup.inspect() {
            setupSnapshot = inspected
            systemHealth?.isConfigured = inspected.phase.isConfigured
        }
        refreshDurableStatus()
    }

    func configureAfterReview() {
        guard let guidedSetup, !setupIsWorking else { return }
        setupIsWorking = true
        setupFailed = false
        setupHooksChanged = false
        Task {
            do {
                setupSnapshot = try await Task.detached {
                    try guidedSetup.configureAfterReview()
                }.value
                systemHealth?.isConfigured = setupSnapshot.phase.isConfigured
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

    var menuBarSymbol: String {
        currentSignalPresentation.systemImage
    }

    var currentSignalPresentation: AggregateSignalPresentation {
        snapshot.currentSignal.presentation(in: snapshot.profile)
    }

    var menuState: MenuState {
        switch setupSnapshot.phase {
        case .codexHostMissing, .hookReview: .configurationRequired
        case .configured: .configured
        case .ready: .ready
        }
    }

    private func refreshDurableStatus() {
        if setupSnapshot.phase == .configured,
            let guidedSetup,
            let inspected = try? guidedSetup.inspect()
        {
            setupSnapshot = inspected
            systemHealth?.isConfigured = inspected.phase.isConfigured
        }
        snapshot = lifecycle.refresh()
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
