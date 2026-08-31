import Foundation

public enum CodexHost: String, Hashable, Sendable {
    case desktopApp
    case commandLine
}

public enum HookEvent: String, CaseIterable, Sendable {
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case sessionEnd = "SessionEnd"
    case sessionStart = "SessionStart"
    case stop = "Stop"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case userPromptSubmit = "UserPromptSubmit"
}

public enum HookField: String, CaseIterable, Sendable {
    case event = "hook_event_name"
    case session = "session_id"
    case agent = "agent_id"
    case turn = "turn_id"
    case receivedAt = "received_at"
}

public struct HookDefinition: Equatable, Sendable {
    public let event: HookEvent
    public let allowedFields: Set<HookField>
    public let reviewedHash: String

    public init(event: HookEvent, allowedFields: Set<HookField>, reviewedHash: String) {
        self.event = event
        self.allowedFields = allowedFields
        self.reviewedHash = reviewedHash
    }

    public static let reviewedRelease: [HookDefinition] = [
        HookDefinition(event: .permissionRequest, allowedFields: [.event, .session, .agent, .turn, .receivedAt], reviewedHash: "sha256:5f25dca9d0ce796a5c7169e57b0fd97b90af4a3fe4329fba791a35aff00fd321"),
        HookDefinition(event: .postToolUse, allowedFields: [.event, .session, .agent, .turn, .receivedAt], reviewedHash: "sha256:7cc58a7a6b7d62914e65120af0b388a61824fa237d8bcdff2d0e8f2f86dcd49f"),
        HookDefinition(event: .sessionEnd, allowedFields: [.event, .session, .receivedAt], reviewedHash: "sha256:45290ede59950ec464758a3b5f3aca05bc0184a0f456a2dee6f2ca87a65334c9"),
        HookDefinition(event: .sessionStart, allowedFields: [.event, .session, .receivedAt], reviewedHash: "sha256:8d0997952af595e40966d18a4b970ddfde9b1082c99d154374e209c4723d9b75"),
        HookDefinition(event: .stop, allowedFields: [.event, .session, .turn, .receivedAt], reviewedHash: "sha256:e20bbf3639086f8545a28998eac049fba54d63f8fb0b5876e0b43d6f1f0cd34d"),
        HookDefinition(event: .subagentStart, allowedFields: [.event, .session, .agent, .turn, .receivedAt], reviewedHash: "sha256:01946b08cd49609fe0cc4a8e43959cd3ebf29ab011278f51d9f77abdbd032a98"),
        HookDefinition(event: .subagentStop, allowedFields: [.event, .session, .agent, .turn, .receivedAt], reviewedHash: "sha256:36375c4c50d15317921135227d6c423f134853c725df334433a38f47fe918c40"),
        HookDefinition(event: .userPromptSubmit, allowedFields: [.event, .session, .turn, .receivedAt], reviewedHash: "sha256:af395f0d95e15ee1a97f0437eedb1859cdea89b94225d88ba706619e661b9a20"),
    ]
}

public enum GuidedSetupPhase: Equatable, Sendable {
    case codexHostMissing
    case hookReview
    case configured
    case ready
}

public enum GuidedSetupError: Error, Equatable, Sendable {
    case codexHostMissing
    case reviewedHooksChanged
}

public struct GuidedSetupSnapshot: Equatable, Sendable {
    public let phase: GuidedSetupPhase
    public let detectedHosts: Set<CodexHost>
    public let hooks: [HookDefinition]

    public init(phase: GuidedSetupPhase, detectedHosts: Set<CodexHost>, hooks: [HookDefinition]) {
        self.phase = phase
        self.detectedHosts = detectedHosts
        self.hooks = hooks
    }
}

public struct SetupIntegrationHealth: Equatable, Sendable {
    public let pluginInstalled: Bool
    public let hooksTrusted: Bool
    public let companionRegistered: Bool
    public let managedStatePresent: Bool

    public init(
        pluginInstalled: Bool,
        hooksTrusted: Bool,
        companionRegistered: Bool,
        managedStatePresent: Bool
    ) {
        self.pluginInstalled = pluginInstalled
        self.hooksTrusted = hooksTrusted
        self.companionRegistered = companionRegistered
        self.managedStatePresent = managedStatePresent
    }

    public static let notConfigured = SetupIntegrationHealth(
        pluginInstalled: false,
        hooksTrusted: false,
        companionRegistered: false,
        managedStatePresent: false
    )

    public var isConfigured: Bool {
        pluginInstalled && hooksTrusted && companionRegistered && managedStatePresent
    }
}

public protocol CodexHostDetecting {
    func detectHosts() throws -> Set<CodexHost>
}

public protocol SetupKeyboardHealthProviding {
    func currentKeyboardHealth() -> KeyboardHealth
}

public protocol GuidedSetupIntegrating: AnyObject {
    func health() throws -> SetupIntegrationHealth
    func stage(_ hooks: [HookDefinition]) throws
    func installedHookHashes() throws -> [HookEvent: String]
    func trust(_ hooks: [HookDefinition]) throws
    func registerCompanion() throws
    func persistConfigured() throws
}

public final class GuidedSetup: @unchecked Sendable {
    private let hosts: any CodexHostDetecting
    private let integration: any GuidedSetupIntegrating
    private let keyboard: any SetupKeyboardHealthProviding

    public init(
        hosts: any CodexHostDetecting,
        integration: any GuidedSetupIntegrating,
        keyboard: any SetupKeyboardHealthProviding
    ) {
        self.hosts = hosts
        self.integration = integration
        self.keyboard = keyboard
    }

    public func inspect() throws -> GuidedSetupSnapshot {
        let detectedHosts = try hosts.detectHosts()
        guard !detectedHosts.isEmpty else {
            return GuidedSetupSnapshot(
                phase: .codexHostMissing,
                detectedHosts: [],
                hooks: HookDefinition.reviewedRelease
            )
        }
        guard try integration.health().isConfigured else {
            return GuidedSetupSnapshot(
                phase: .hookReview,
                detectedHosts: detectedHosts,
                hooks: HookDefinition.reviewedRelease
            )
        }
        let phase: GuidedSetupPhase = keyboard.currentKeyboardHealth()
            == .connected(protocolHealthy: true) ? .ready : .configured
        return GuidedSetupSnapshot(
            phase: phase,
            detectedHosts: detectedHosts,
            hooks: HookDefinition.reviewedRelease
        )
    }

    public func configureAfterReview() throws -> GuidedSetupSnapshot {
        let detectedHosts = try hosts.detectHosts()
        guard !detectedHosts.isEmpty else {
            throw GuidedSetupError.codexHostMissing
        }
        let reviewedHooks = HookDefinition.reviewedRelease
        let health = try integration.health()
        if !health.pluginInstalled {
            try integration.stage(reviewedHooks)
        }
        let installedHashes = try integration.installedHookHashes()
        let reviewedHashes = Dictionary(
            uniqueKeysWithValues: reviewedHooks.map { ($0.event, $0.reviewedHash) }
        )
        guard installedHashes == reviewedHashes else {
            throw GuidedSetupError.reviewedHooksChanged
        }
        if !health.hooksTrusted {
            try integration.trust(reviewedHooks)
        }
        if !health.companionRegistered {
            try integration.registerCompanion()
        }
        if !health.managedStatePresent {
            try integration.persistConfigured()
        }
        let phase: GuidedSetupPhase = keyboard.currentKeyboardHealth()
            == .connected(protocolHealthy: true) ? .ready : .configured
        return GuidedSetupSnapshot(
            phase: phase,
            detectedHosts: detectedHosts,
            hooks: reviewedHooks
        )
    }
}
