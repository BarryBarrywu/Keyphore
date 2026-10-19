import Foundation

public enum AgentIntegrationAssets {
    public static func files(for source: AgentSource, helperURL: URL) throws -> [String: Data] {
        switch source {
        case .codex:
            return [:]
        case .pi, .opencode:
            let name = source == .pi ? "keyphore.ts" : "keyphore.js"
            let template = try resourceData(source: source, path: "\(name).template")
            let helper = try JSONEncoder().encode(helperURL.path)
            let rendered = String(decoding: template, as: UTF8.self).replacingOccurrences(
                of: "__KEYPHORE_HELPER_URL_JSON__",
                with: String(decoding: helper, as: UTF8.self)
            )
            return [name: Data(rendered.utf8)]
        case .claudeCode, .qodercli, .grok:
            return try resourceFiles(source: source)
        }
    }

    public static func events(for source: AgentSource) -> [String] {
        switch source {
        case .codex:
            []
        case .claudeCode:
            [
                "SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure",
                "PermissionRequest", "Notification", "SubagentStart", "SubagentStop", "Stop",
                "StopFailure", "SessionEnd",
            ]
        case .pi:
            ["session_start", "agent_start", "message_end", "agent_settled", "session_shutdown"]
        case .opencode:
            [
                "session.created", "session.status", "permission.asked", "permission.replied",
                "question.asked", "question.replied", "question.rejected", "session.error",
                "session.deleted",
            ]
        case .qodercli:
            [
                "SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure",
                "PermissionRequest", "Notification", "SubagentStart", "SubagentStop", "Stop",
                "StopFailure", "SessionEnd",
            ]
        case .grok:
            [
                "SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure",
                "Notification", "SubagentStart", "SubagentStop", "Stop", "StopFailure",
                "StopCancelled", "SessionEnd",
            ]
        }
    }

    private static func resourceData(source: AgentSource, path: String) throws -> Data {
        try Data(contentsOf: try resourceRoot(source: source).appending(path: path))
    }

    private static func resourceFiles(source: AgentSource) throws -> [String: Data] {
        let root = try resourceRoot(source: source)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var files: [String: Data] = [:]
        for case let url as URL in enumerator
        where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let resolvedURL = url.resolvingSymlinksInPath()
            let relative = String(resolvedURL.path.dropFirst(root.path.count + 1))
            files[relative] = try Data(contentsOf: resolvedURL)
        }
        return files
    }

    private static func resourceRoot(source: AgentSource) throws -> URL {
        guard let root = Bundle.module.url(forResource: "AgentIntegrationResources", withExtension: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return root.appending(path: source.rawValue, directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
    }
}
