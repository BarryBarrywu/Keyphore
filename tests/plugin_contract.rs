use std::fs;
use std::os::unix::fs::PermissionsExt;

use serde_json::Value;

#[test]
fn plugin_bundles_only_the_nuphy_companion_and_owned_hooks() {
    let manifest: Value =
        serde_json::from_slice(&fs::read("plugin/.codex-plugin/plugin.json").unwrap()).unwrap();
    assert_eq!(manifest["name"], "nuphy-codex");
    assert_eq!(manifest["version"], env!("CARGO_PKG_VERSION"));

    let companion = fs::metadata("plugin/bin/nuphy-codex").unwrap();
    assert!(companion.is_file());
    assert_ne!(companion.permissions().mode() & 0o111, 0);
    let notice = fs::read_to_string("plugin/LICENSES/NUPHYIO-NOTICE.txt").unwrap();
    assert!(notice.contains("nuphyctl"));
    assert!(notice.contains("codex-kick75-status-lights"));
    assert!(notice.contains("MIT License"));

    let hooks: Value =
        serde_json::from_slice(&fs::read("plugin/hooks/hooks.json").unwrap()).unwrap();
    let hooks = hooks["hooks"].as_object().unwrap();
    assert_eq!(
        hooks.keys().map(String::as_str).collect::<Vec<_>>(),
        [
            "PermissionRequest",
            "PostToolUse",
            "SessionEnd",
            "SessionStart",
            "Stop",
            "SubagentStart",
            "SubagentStop",
            "UserPromptSubmit",
        ]
    );

    for definitions in hooks.values() {
        let handler = &definitions[0]["hooks"][0];
        assert_eq!(handler["type"], "command");
        let command = handler["command"].as_str().unwrap();
        assert_eq!(command, "\"${CLAUDE_PLUGIN_ROOT}/bin/nuphy-codex\" hook");
        for forbidden in ["python", "node", "nuphyctl", "zectrix"] {
            assert!(!command.to_ascii_lowercase().contains(forbidden));
        }
    }

    let setup = fs::read_to_string("plugin/skills/setup-nuphy-codex/SKILL.md").unwrap();
    assert!(setup.contains("lifecycle install"));
    assert!(setup.contains("lifecycle validate"));
    assert!(setup.contains("lifecycle update"));
    assert!(setup.contains("lifecycle uninstall"));
    assert!(!setup.to_ascii_lowercase().contains("python"));
    assert!(!setup.to_ascii_lowercase().contains("node"));
    assert!(!setup.to_ascii_lowercase().contains("nuphyctl"));
    assert!(!setup.to_ascii_lowercase().contains("zectrix"));
}
