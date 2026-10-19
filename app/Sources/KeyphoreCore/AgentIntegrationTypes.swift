import Foundation

public enum AgentSource: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCode = "claude-code"
    case pi, opencode, qodercli, grok

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .pi: "Pi"
        case .opencode: "OpenCode"
        case .qodercli: "Qoder CLI"
        case .grok: "Grok"
        }
    }

    public var executableName: String { self == .claudeCode ? "claude" : rawValue }
    public var supportsAttention: Bool { self != .pi }
}

public struct AgentSignalEvent: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case sessionStart, sessionEnd, turnStart, working, attention, attentionResolved
        case turnComplete, turnCancelled, agentStart, agentEnd
    }

    public let source: AgentSource
    public let kind: Kind
    public let sessionID: String
    public let agentID: String
    public let turnID: String?
    public let requestID: String?

    public init(
        source: AgentSource, kind: Kind, sessionID: String, agentID: String = "main",
        turnID: String? = nil, requestID: String? = nil
    ) {
        self.source = source
        self.kind = kind
        self.sessionID = sessionID
        self.agentID = agentID
        self.turnID = turnID
        self.requestID = requestID
    }
}

public struct AgentSourceConsent: Codable, Equatable, Sendable {
    public let approvalID: String
    public var enabled: Bool
    public var definitionDigest: String
    public var runtimeDigest: String
    public var assets: [String: String]

    public init(enabled: Bool, definitionDigest: String, runtimeDigest: String, assets: [String: String],
                approvalID: String = UUID().uuidString) {
        self.approvalID = approvalID
        self.enabled = enabled
        self.definitionDigest = definitionDigest
        self.runtimeDigest = runtimeDigest
        self.assets = assets
    }
}

public struct AgentIntegrationManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sources: [String: AgentSourceConsent]

    public init(schemaVersion: Int = 1, sources: [String: AgentSourceConsent] = [:]) {
        self.schemaVersion = schemaVersion
        self.sources = sources
    }
}

public struct AgentIntegrationConsentStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> AgentIntegrationManifest {
        do {
            let manifest = try JSONDecoder().decode(AgentIntegrationManifest.self, from: Data(contentsOf: url))
            guard manifest.schemaVersion == 1 else { throw GuidedSetupError.invalidHookInput }
            return manifest
        } catch CocoaError.fileReadNoSuchFile {
            return AgentIntegrationManifest()
        }
    }

    public func save(_ manifest: AgentIntegrationManifest) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    public func isApproved(source: AgentSource, runtimeURL: URL) -> Bool {
        guard let consent = try? load().sources[source.rawValue], consent.enabled,
              !consent.definitionDigest.isEmpty,
              let data = try? Data(contentsOf: runtimeURL)
        else { return false }
        return ManagedRuntimeIntegrity.digest(data) == consent.runtimeDigest
    }
}

extension KeyphoreRuntimePaths {
    public static func agentIntegrationsURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        supportDirectory(homeDirectory: homeDirectory).appending(path: "agent-integrations.json")
    }
}
