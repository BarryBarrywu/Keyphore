import Foundation
import KeyphoreCore

@MainActor
final class KeyphoreAppState: ObservableObject {
    @Published private(set) var snapshot: LifecycleSnapshot
    @Published private(set) var setupSnapshot: GuidedSetupSnapshot
    @Published private(set) var setupFailed = false
    @Published private(set) var setupIsWorking = false

    private let lifecycle: KeyphoreLifecycle
    private let guidedSetup: GuidedSetup?

    init(lifecycle: KeyphoreLifecycle, guidedSetup: GuidedSetup? = nil) {
        self.lifecycle = lifecycle
        let initialSnapshot = lifecycle.refresh()
        snapshot = initialSnapshot
        self.guidedSetup = guidedSetup
        setupSnapshot = Self.initialSetupSnapshot(for: initialSnapshot)
        if let guidedSetup, let inspected = try? guidedSetup.inspect() {
            setupSnapshot = inspected
        }
    }

    convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let fixture = AcceptanceFixture(environment["KEYPHORE_ACCEPTANCE_FIXTURE"])
        let lifecycle = KeyphoreLifecycle(
            health: FixtureHealthAdapter(health: fixture.health),
            profiles: FixtureProfileAdapter(),
            durableStatus: FixtureDurableStatusAdapter(outcome: fixture.outcome),
            lighting: FixtureLightingAdapter(),
            runtime: FixtureRuntimeAdapter()
        )
        self.init(
            lifecycle: lifecycle,
            guidedSetup: environment["KEYPHORE_ACCEPTANCE_FIXTURE"] == nil ? .system() : nil
        )
    }

    func refresh() {
        snapshot = lifecycle.refresh()
        if let guidedSetup, let inspected = try? guidedSetup.inspect() {
            setupSnapshot = inspected
        }
    }

    func configureAfterReview() {
        guard let guidedSetup, !setupIsWorking else { return }
        setupIsWorking = true
        setupFailed = false
        Task {
            do {
                setupSnapshot = try await Task.detached {
                    try guidedSetup.configureAfterReview()
                }.value
            } catch {
                setupFailed = true
            }
            setupIsWorking = false
        }
    }

    func prepareToQuit() {
        lifecycle.quit()
    }

    var menuBarSymbol: String {
        snapshot.currentSignal.presentation(in: snapshot.profile).systemImage
    }

    var menuState: MenuState {
        switch setupSnapshot.phase {
        case .codexHostMissing, .hookReview: .configurationRequired
        case .configured: .configured
        case .ready: .ready
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

private struct FixtureDurableStatusAdapter: DurableStatusProviding {
    let outcome: DurableStatusOutcome
    func currentOutcome() -> DurableStatusOutcome { outcome }
}

private final class FixtureLightingAdapter: LightingEmitting {
    func emit(_ behavior: LightingBehavior) {}
}

private final class FixtureRuntimeAdapter: KeyphoreRuntimeManaging {
    func disableOwnedHooks() {}
    func stopCompanion() {}
    func clearManagedRuntimeState() {}
}
