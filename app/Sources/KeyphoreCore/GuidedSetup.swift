import Foundation
import CryptoKit

public enum CodexHost: String, Hashable, Sendable {
    case desktopApp
    case commandLine
}

public enum CodexRuntimeCompatibility {
    public static let appServerArguments = ["app-server"]

    public static func preferredURL(commandLine: URL?, desktop: URL?) -> URL? {
        commandLine ?? desktop
    }
}

public struct CodexHookMetadata: Decodable {
    public let key: String
    public let eventName: String
    public let handlerType: String
    public let executionMode: String?
    public let matcher: String?
    public let command: String?
    public let timeoutSec: UInt64
    public let statusMessage: String?
    public let additionalContextLimit: UInt64?
    public let sourcePath: String
    public let pluginID: String?
    public let enabled: Bool
    public let isManaged: Bool
    public let currentHash: String
    public let trustStatus: String

    public var event: HookEvent? {
        HookEvent.allCases.first {
            $0.rawValue.prefix(1).lowercased() + $0.rawValue.dropFirst() == eventName
        }
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case eventName
        case handlerType
        case executionMode
        case matcher
        case command
        case timeoutSec
        case statusMessage
        case additionalContextLimit
        case sourcePath
        case pluginID = "pluginId"
        case enabled
        case isManaged
        case currentHash
        case trustStatus
    }
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
    public let command: String
    public let timeoutSeconds: UInt64

    public init(
        event: HookEvent,
        allowedFields: Set<HookField>,
        reviewedHash: String,
        command: String = "\"${PLUGIN_ROOT}/bin/keyphore\" hook",
        timeoutSeconds: UInt64 = 1
    ) {
        self.event = event
        self.allowedFields = allowedFields
        self.reviewedHash = reviewedHash
        self.command = command
        self.timeoutSeconds = timeoutSeconds
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

    public static let reviewedHashes = Dictionary(
        uniqueKeysWithValues: reviewedRelease.map { ($0.event, $0.reviewedHash) }
    )

    public static let reviewedReleaseDigest = digest(for: reviewedRelease)

    public static func digest(for definitions: [HookDefinition]) -> String {
        let canonical = definitions.map { definition in
            let fields = definition.allowedFields.map(\.rawValue).sorted().joined(separator: ",")
            return [
                definition.event.rawValue,
                fields,
                definition.command,
                String(definition.timeoutSeconds),
                definition.reviewedHash,
            ].joined(separator: "|")
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum ManagedRuntimeIntegrity {
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func isCurrent(
        recordedDigest: String?,
        runtimeURLs: [URL],
        fileManager: FileManager = .default
    ) -> Bool {
        guard let recordedDigest, !runtimeURLs.isEmpty else { return false }
        for url in runtimeURLs {
            guard
                fileManager.isExecutableFile(atPath: url.path),
                let data = try? Data(contentsOf: url),
                digest(data) == recordedDigest
            else {
                return false
            }
        }
        return true
    }
}

public struct PrivacyAllowedHookRecord: Equatable, Sendable {
    public let event: HookEvent
    public let sessionID: String?
    public let agentID: String?
    public let turnID: String?
    public let receivedAt: String

    public init(jsonData: Data, receivedAt: String) throws {
        guard
            let input = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let eventName = input[HookField.event.rawValue] as? String,
            let event = HookEvent(rawValue: eventName),
            let definition = HookDefinition.reviewedRelease.first(where: { $0.event == event })
        else {
            throw GuidedSetupError.invalidHookInput
        }
        self.event = event
        sessionID = definition.allowedFields.contains(.session)
            ? input[HookField.session.rawValue] as? String
            : nil
        agentID = definition.allowedFields.contains(.agent)
            ? input[HookField.agent.rawValue] as? String
            : nil
        turnID = definition.allowedFields.contains(.turn)
            ? input[HookField.turn.rawValue] as? String
            : nil
        self.receivedAt = receivedAt
    }

    public func encoded() throws -> Data {
        var fields = [
            HookField.event.rawValue: event.rawValue,
            HookField.receivedAt.rawValue: receivedAt,
        ]
        fields[HookField.session.rawValue] = sessionID
        fields[HookField.agent.rawValue] = agentID
        fields[HookField.turn.rawValue] = turnID
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }
}

public enum GuidedSetupPhase: Equatable, Sendable {
    case codexHostMissing
    case hookReview
    case configured
    case ready
}

public enum GuidedSetupError: Error, Equatable, Sendable {
    case codexHostMissing
    case configurationIncomplete
    case invalidHookInput
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
        if !health.pluginInstalled || !health.hooksTrusted || !health.managedStatePresent {
            try integration.stage(reviewedHooks)
        }
        let installedHashes = try integration.installedHookHashes()
        guard installedHashes == HookDefinition.reviewedHashes else {
            throw GuidedSetupError.reviewedHooksChanged
        }
        if !health.hooksTrusted {
            try integration.trust(reviewedHooks)
        }
        if !health.companionRegistered || !health.managedStatePresent {
            try integration.registerCompanion()
        }
        if !health.managedStatePresent {
            try integration.persistConfigured()
        }
        guard try integration.health().isConfigured else {
            throw GuidedSetupError.configurationIncomplete
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
