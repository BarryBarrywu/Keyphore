import Foundation

public enum KeyboardHealth: Equatable, Sendable {
    case disconnected
    case connected(protocolHealthy: Bool)
}

public struct KeyphoreHealth: Equatable, Sendable {
    public let isConfigured: Bool
    public let keyboard: KeyboardHealth

    public init(isConfigured: Bool, keyboard: KeyboardHealth) {
        self.isConfigured = isConfigured
        self.keyboard = keyboard
    }

    public static func configured(keyboard: KeyboardHealth) -> KeyphoreHealth {
        KeyphoreHealth(isConfigured: true, keyboard: keyboard)
    }

    public static let configurationRequired = KeyphoreHealth(
        isConfigured: false,
        keyboard: .disconnected
    )
}

public enum CodexSignal: String, Codable, Hashable, Sendable {
    case execution
    case attention
    case completion
}

public struct DurableStatusOutcome: Equatable, Sendable {
    public let activeSignals: Set<CodexSignal>

    public init(activeSignals: Set<CodexSignal>) {
        self.activeSignals = activeSignals
    }

    public static func active(_ signals: Set<CodexSignal>) -> DurableStatusOutcome {
        DurableStatusOutcome(activeSignals: signals)
    }

    public static let signalOff = DurableStatusOutcome(activeSignals: [])
    public static let execution = DurableStatusOutcome(activeSignals: [.execution])
    public static let attention = DurableStatusOutcome(activeSignals: [.attention])
    public static let completion = DurableStatusOutcome(activeSignals: [.completion])
}

public enum AggregateSignal: Equatable, Sendable {
    case signalOff
    case execution
    case attention
    case completion
}

public enum MenuState: Equatable, Sendable {
    case configurationRequired
    case configured
    case ready
}

public struct LifecycleSnapshot: Equatable, Sendable {
    public let health: KeyphoreHealth
    public let menuState: MenuState
    public let durableStatus: DurableStatusOutcome
    public let currentSignal: AggregateSignal
    public let profile: LocalProfile

    public var keyboardHealth: KeyboardHealth { health.keyboard }

    public init(
        health: KeyphoreHealth,
        menuState: MenuState,
        durableStatus: DurableStatusOutcome,
        currentSignal: AggregateSignal,
        profile: LocalProfile
    ) {
        self.health = health
        self.menuState = menuState
        self.durableStatus = durableStatus
        self.currentSignal = currentSignal
        self.profile = profile
    }
}

@MainActor
public protocol KeyphoreHealthProviding {
    func currentHealth() -> KeyphoreHealth
}

@MainActor
public protocol LocalProfileProviding {
    func currentProfile() -> LocalProfile
}

@MainActor
public protocol DurableStatusProviding {
    func currentOutcome() -> DurableStatusOutcome
}

@MainActor
public protocol LightingEmitting: AnyObject {
    func emit(_ behavior: LightingBehavior)
}

@MainActor
public protocol KeyphoreRuntimeManaging: AnyObject {
    func disableOwnedHooks()
    func stopCompanion()
    func clearManagedRuntimeState()
}

@MainActor
public final class KeyphoreLifecycle {
    private let health: any KeyphoreHealthProviding
    private let profiles: any LocalProfileProviding
    private let durableStatus: any DurableStatusProviding
    private let lighting: any LightingEmitting
    private let runtime: any KeyphoreRuntimeManaging

    public init(
        health: any KeyphoreHealthProviding,
        profiles: any LocalProfileProviding,
        durableStatus: any DurableStatusProviding,
        lighting: any LightingEmitting,
        runtime: any KeyphoreRuntimeManaging
    ) {
        self.health = health
        self.profiles = profiles
        self.durableStatus = durableStatus
        self.lighting = lighting
        self.runtime = runtime
    }

    public func refresh() -> LifecycleSnapshot {
        let currentHealth = health.currentHealth()
        let currentProfile = profiles.currentProfile()
        let currentOutcome = durableStatus.currentOutcome()
        let currentSignal = currentProfile.aggregateSignal(for: currentOutcome)
        let menuState: MenuState

        if !currentHealth.isConfigured {
            menuState = .configurationRequired
        } else if currentHealth.keyboard == .connected(protocolHealthy: true) {
            menuState = .ready
        } else {
            menuState = .configured
        }

        if menuState == .ready {
            lighting.emit(currentProfile.behavior(for: currentSignal))
        }

        return LifecycleSnapshot(
            health: currentHealth,
            menuState: menuState,
            durableStatus: currentOutcome,
            currentSignal: currentSignal,
            profile: currentProfile
        )
    }

    public func quit() {
        runtime.disableOwnedHooks()
        runtime.stopCompanion()
        runtime.clearManagedRuntimeState()
        lighting.emit(.off)
    }
}
