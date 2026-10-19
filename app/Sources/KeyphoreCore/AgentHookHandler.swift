import Foundation

/// Decodes only routing metadata. Prompt, message, tool arguments and transcript fields are ignored.
public enum AgentHookNormalizer {
    public static func normalize(_ input: Data, source: AgentSource) throws -> AgentSignalEvent? {
        guard input.count <= 1_048_576,
              let fields = try JSONSerialization.jsonObject(with: input) as? [String: Any]
        else { throw GuidedSetupError.invalidHookInput }
        func identifier(_ keys: String...) throws -> String? {
            for key in keys {
                guard let value = fields[key], !(value is NSNull) else { continue }
                guard let string = value as? String, !string.isEmpty, string.utf8.count <= 512,
                      !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                else { throw GuidedSetupError.invalidHookInput }
                return string
            }
            return nil
        }
        guard source != .codex else { throw GuidedSetupError.invalidHookInput }
        let isGrok = source == .grok
        guard let session = try identifier(isGrok ? "sessionId" : "session_id") else {
            throw GuidedSetupError.invalidHookInput
        }
        let agent = try identifier(isGrok ? "agentId" : "agent_id")
        let turn = try identifier(isGrok ? "promptId" : "turn_id")
        let request = try identifier("request_id", isGrok ? "toolUseId" : "tool_use_id")
        let kind: AgentSignalEvent.Kind
        if source == .pi || source == .opencode {
            guard let name = try identifier("event"), let parsed = AgentSignalEvent.Kind(rawValue: name) else {
                return nil
            }
            kind = parsed
        } else {
            guard let name = try identifier("hook_event_name", "hookEventName") else {
                throw GuidedSetupError.invalidHookInput
            }
            // Grok exposes child type but no documented stable child ID. Never let a child settle main.
            if isGrok, let childType = fields["subagentType"] as? String, !childType.isEmpty, agent == nil { return nil }
            switch name {
            case "SessionStart", "session_start": kind = .sessionStart
            case "SessionEnd", "session_end": kind = .sessionEnd
            case "UserPromptSubmit", "user_prompt_submit": kind = .turnStart
            case "SubagentStart", "subagent_start": kind = .agentStart
            case "SubagentStop", "subagent_stop": kind = .agentEnd
            case "PreToolUse", "pre_tool_use": kind = .working
            case "PostToolUse", "post_tool_use", "PostToolUseFailure", "post_tool_use_failure":
                kind = .attentionResolved
            case "PermissionRequest" where !isGrok: kind = .attention
            case "StopFailure", "StopCancelled", "stop_failure", "stop_cancelled": kind = .turnCancelled
            case "Stop", "stop":
                let reason = fields["reason"] as? String
                kind = isGrok && ["channel_closed", "shutdown"].contains(reason) ? .sessionEnd : .turnComplete
            case "Notification", "notification":
                switch fields[isGrok ? "notificationType" : "notification_type"] as? String {
                case "permission_prompt", "elicitation_dialog": kind = .attention
                case "idle_prompt" where isGrok && turn != nil: kind = .turnCancelled
                default: return nil
                }
            default: return nil
            }
        }
        if kind == .agentStart || kind == .agentEnd {
            guard let agent, agent != "main" else { return nil }
        }
        if !source.supportsAttention && (kind == .attention || kind == .attentionResolved) { return nil }
        return AgentSignalEvent(source: source, kind: kind, sessionID: session, agentID: agent ?? "main",
                                turnID: turn, requestID: request)
    }
}

public final class AgentHookHandler {
    private let store: DurableStatusStore
    private let source: AgentSource
    private let consentStore: AgentIntegrationConsentStore
    private let runtimeURL: URL
    private let quitGate: QuitGateStore
    private let lockBudget: Duration
    private let invokedByGrok: Bool
    private let completionDurationProvider: () throws -> CompletionDisplayDuration

    public init(
        store: DurableStatusStore, source: AgentSource,
        consentStore: AgentIntegrationConsentStore, runtimeURL: URL, quitGate: QuitGateStore,
        lockBudget: Duration = .milliseconds(100),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        completionDurationProvider: @escaping () throws -> CompletionDisplayDuration = { .fiveSeconds }
    ) {
        self.store = store
        self.source = source
        self.consentStore = consentStore
        self.runtimeURL = runtimeURL
        self.quitGate = quitGate
        self.lockBudget = lockBudget
        self.invokedByGrok = environment["GROK_PLUGIN_ROOT"] != nil
        self.completionDurationProvider = completionDurationProvider
    }

    public func handle(_ input: Data, receivedAt: StatusTimestamp = .now) throws {
        // Grok can import Claude plugins. Imported hooks must not borrow another source's consent.
        guard !(invokedByGrok && (source == .claudeCode || source == .qodercli)),
              !quitGate.isActive, consentStore.isApproved(source: source, runtimeURL: runtimeURL) else { return }
        guard let event = try AgentHookNormalizer.normalize(input, source: source) else { return }
        try store.apply(event, at: receivedAt,
                        completionLifetime: .seconds(Int64(try completionDurationProvider().seconds)),
                        lockBudget: lockBudget, isAuthorized: {
                            !self.quitGate.isActive
                                && self.consentStore.isApproved(source: self.source, runtimeURL: self.runtimeURL)
                        })
    }
}
