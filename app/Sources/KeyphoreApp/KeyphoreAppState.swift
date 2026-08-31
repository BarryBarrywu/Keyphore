import Foundation
import KeyphoreCore

@MainActor
final class KeyphoreAppState: ObservableObject {
    @Published private(set) var snapshot: LifecycleSnapshot

    private let lifecycle: KeyphoreLifecycle

    init(lifecycle: KeyphoreLifecycle) {
        self.lifecycle = lifecycle
        snapshot = lifecycle.refresh()
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
        self.init(lifecycle: lifecycle)
    }

    func refresh() {
        snapshot = lifecycle.refresh()
    }

    func prepareToQuit() {
        lifecycle.quit()
    }

    var menuBarSymbol: String {
        snapshot.currentSignal.presentation(in: snapshot.profile).systemImage
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
