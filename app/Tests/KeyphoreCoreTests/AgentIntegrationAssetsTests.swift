import Foundation
import XCTest
@testable import KeyphoreCore

final class AgentIntegrationAssetsTests: XCTestCase {
    private let helper = URL(filePath: "/Users/example/Library/Application Support/Keyphore/agent-integrations/pi/bin/keyphore")

    func testCodexKeepsItsExistingIntegrationPath() throws {
        XCTAssertEqual(try AgentIntegrationAssets.files(for: .codex, helperURL: helper), [:])
        XCTAssertEqual(AgentIntegrationAssets.events(for: .codex), [])
    }

    func testNativePluginsContainOnlyManifestAndReviewedHooks() throws {
        let expectations: [(AgentSource, String, String, String)] = [
            (.claudeCode, ".claude-plugin/plugin.json", "CLAUDE_PLUGIN_ROOT", "keyphore-claude-code"),
            (.qodercli, ".qoder-plugin/plugin.json", "QODER_PLUGIN_ROOT", "keyphore-qodercli"),
            (.grok, ".grok-plugin/plugin.json", "GROK_PLUGIN_ROOT", "keyphore-grok"),
        ]

        for (source, manifestPath, rootVariable, pluginName) in expectations {
            let files = try AgentIntegrationAssets.files(for: source, helperURL: helper)
            let expectedFiles = source == .claudeCode
                ? [manifestPath, ".claude-plugin/marketplace.json", "hooks/hooks.json"]
                : [manifestPath, "hooks/hooks.json"]
            XCTAssertEqual(Set(files.keys), Set(expectedFiles))

            let manifest = try XCTUnwrap(try json(files[manifestPath]))
            XCTAssertEqual(manifest["name"] as? String, pluginName)
            XCTAssertEqual(manifest["version"] as? String, "0.2.0")

            let hooksJSON = String(decoding: try XCTUnwrap(files["hooks/hooks.json"]), as: UTF8.self)
            XCTAssertTrue(hooksJSON.contains("${\(rootVariable)}/bin/keyphore"))
            XCTAssertTrue(hooksJSON.contains("hook \(source.rawValue)"))
            XCTAssertFalse(hooksJSON.contains("mcp"))
        }
    }

    func testClaudeMarketplaceCatalogPointsAtTheStagedPluginRoot() throws {
        let files = try AgentIntegrationAssets.files(for: .claudeCode, helperURL: helper)
        let catalog = try XCTUnwrap(try json(files[".claude-plugin/marketplace.json"]))
        XCTAssertEqual(catalog["name"] as? String, "keyphore-app")
        XCTAssertEqual((catalog["owner"] as? [String: Any])?["name"] as? String, "Keyphore")
        let plugins = try XCTUnwrap(catalog["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins[0]["name"] as? String, "keyphore-claude-code")
        XCTAssertEqual(plugins[0]["source"] as? String, "./")
        XCTAssertEqual(plugins[0]["version"] as? String, "0.2.0")
    }

    func testNativeHookDeclarationsMatchReviewedEvents() throws {
        for source in [AgentSource.claudeCode, .qodercli, .grok] {
            let files = try AgentIntegrationAssets.files(for: source, helperURL: helper)
            let document = try XCTUnwrap(try json(files["hooks/hooks.json"]))
            let hooks = try XCTUnwrap(document["hooks"] as? [String: Any])
            XCTAssertEqual(Set(hooks.keys), Set(AgentIntegrationAssets.events(for: source)))
        }
    }

    func testClaudeDeclaresDocumentedFailureWithoutGrokOnlyCancellation() throws {
        let files = try AgentIntegrationAssets.files(for: .claudeCode, helperURL: helper)
        let text = String(decoding: try XCTUnwrap(files["hooks/hooks.json"]), as: UTF8.self)
        XCTAssertTrue(text.contains("StopFailure"))
        XCTAssertFalse(text.contains("StopCancelled"))
    }

    func testGeneratedBridgesInjectTheExactHelperPathWithoutPrivatePayloadFields() throws {
        for source in [AgentSource.pi, .opencode] {
            let files = try AgentIntegrationAssets.files(for: source, helperURL: helper)
            let name = source == .pi ? "keyphore.ts" : "keyphore.js"
            let text = String(decoding: try XCTUnwrap(files[name]), as: UTF8.self)
            XCTAssertTrue(text.contains(try jsonString(helper.path)))
            XCTAssertFalse(text.contains("__KEYPHORE_HELPER_URL_JSON__"))
            for privateField in ["prompt", "message.body", "toolInput", "tool_output", "questions:"] {
                XCTAssertFalse(text.contains(privateField))
            }
        }
    }

    func testPiUsesOnlyDocumentedLifecycleEvents() {
        XCTAssertEqual(AgentIntegrationAssets.events(for: .pi), [
            "session_start", "agent_start", "message_end", "agent_settled", "session_shutdown",
        ])
    }

    func testOpenCodeUsesRequestIDsAndTracksConcurrentPrompts() throws {
        let files = try AgentIntegrationAssets.files(for: .opencode, helperURL: helper)
        let text = String(decoding: try XCTUnwrap(files["keyphore.js"]), as: UTF8.self)
        XCTAssertTrue(text.contains("pending: new Set()"))
        XCTAssertTrue(text.contains("properties.requestID"))
        XCTAssertTrue(text.contains("type === \"retry\""))
        XCTAssertTrue(text.contains("state.pending.size"))
    }

    private func json(_ data: Data?) throws -> [String: Any]? {
        guard let data else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
