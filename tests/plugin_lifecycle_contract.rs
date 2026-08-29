use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Fixture {
    _temp: tempfile::TempDir,
    data_dir: PathBuf,
    launch_agents_dir: PathBuf,
    launchctl: PathBuf,
    codex: PathBuf,
    command_log: PathBuf,
    plugin_state: PathBuf,
    plugin_root: PathBuf,
    other_product_state: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let plugin_root = temp.path().join("plugin-v1");
        copy_plugin_fixture(&plugin_root);
        let command_log = temp.path().join("commands.log");
        let plugin_state = temp.path().join("plugins.txt");
        fs::write(
            &plugin_state,
            "nuphy-codex@local\ncodex-zectrix-dashboard@codex-zectrix-dashboard\n",
        )
        .unwrap();
        let launchctl = executable(
            temp.path().join("launchctl"),
            "#!/bin/sh\nprintf 'launchctl' >> \"$NUPHY_TEST_COMMAND_LOG\"\nprintf ' %s' \"$@\" >> \"$NUPHY_TEST_COMMAND_LOG\"\nprintf '\\n' >> \"$NUPHY_TEST_COMMAND_LOG\"\nif [ \"${1:-}\" = print ]; then printf 'state = running\\n'; fi\nexit 0\n",
        );
        let codex = executable(
            temp.path().join("codex"),
            "#!/bin/sh\nprintf 'codex' >> \"$NUPHY_TEST_COMMAND_LOG\"\nprintf ' %s' \"$@\" >> \"$NUPHY_TEST_COMMAND_LOG\"\nprintf '\\n' >> \"$NUPHY_TEST_COMMAND_LOG\"\nif [ \"${1:-}\" = plugin ] && [ \"${2:-}\" = list ]; then\n  printf '%s\\n' '{\"installed\":[{\"pluginId\":\"nuphy-codex@local\",\"enabled\":true},{\"pluginId\":\"codex-zectrix-dashboard@codex-zectrix-dashboard\",\"enabled\":true}]}'\nelif [ \"${1:-}\" = plugin ] && [ \"${2:-}\" = add ]; then\n  /usr/bin/grep -Fqx \"$3\" \"$NUPHY_TEST_PLUGIN_STATE\" || printf '%s\\n' \"$3\" >> \"$NUPHY_TEST_PLUGIN_STATE\"\nelif [ \"${1:-}\" = plugin ] && [ \"${2:-}\" = remove ]; then\n  /usr/bin/grep -Fvx \"$3\" \"$NUPHY_TEST_PLUGIN_STATE\" > \"$NUPHY_TEST_PLUGIN_STATE.tmp\"\n  /bin/mv \"$NUPHY_TEST_PLUGIN_STATE.tmp\" \"$NUPHY_TEST_PLUGIN_STATE\"\nfi\nexit 0\n",
        );
        let other_product_state = temp.path().join("zectrix-state.json");
        fs::write(&other_product_state, "leave-me-alone").unwrap();
        Self {
            data_dir: temp.path().join("nuphy-data"),
            launch_agents_dir: temp.path().join("LaunchAgents"),
            launchctl,
            codex,
            command_log,
            plugin_state,
            plugin_root,
            other_product_state,
            _temp: temp,
        }
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_nuphy-codex"));
        command
            .env("NUPHY_CODEX_DATA_DIR", &self.data_dir)
            .env("NUPHY_CODEX_LAUNCH_AGENTS_DIR", &self.launch_agents_dir)
            .env("NUPHY_CODEX_LAUNCHCTL_BIN", &self.launchctl)
            .env("NUPHY_CODEX_CODEX_BIN", &self.codex)
            .env("NUPHY_CODEX_LAUNCH_DOMAIN", "gui/501")
            .env("NUPHY_TEST_COMMAND_LOG", &self.command_log);
        command.env("NUPHY_TEST_PLUGIN_STATE", &self.plugin_state);
        command
    }

    fn install(&self) {
        let output = self
            .command()
            .args([
                "lifecycle",
                "install",
                "--plugin-root",
                self.plugin_root.to_str().unwrap(),
                "--plugin-id",
                "nuphy-codex@local",
            ])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn setup_is_idempotent_and_preserves_unrelated_product_state() {
    let fixture = Fixture::new();

    fixture.install();
    fixture.install();

    assert_eq!(
        fs::read_to_string(&fixture.other_product_state).unwrap(),
        "leave-me-alone"
    );
    assert!(
        fs::read_to_string(&fixture.plugin_state)
            .unwrap()
            .contains("codex-zectrix-dashboard@codex-zectrix-dashboard")
    );
    let state = fs::read_to_string(fixture.data_dir.join("lifecycle.json")).unwrap();
    assert!(state.contains("nuphy-codex@local"));
    assert!(!state.to_ascii_lowercase().contains("zectrix"));
    let plist = fs::read_to_string(
        fixture
            .launch_agents_dir
            .join("com.barrybarrywu.nuphy-codex.plist"),
    )
    .unwrap();
    assert!(plist.contains("plugin-v1/bin/nuphy-codex"));
    let calls = fs::read_to_string(&fixture.command_log).unwrap();
    assert!(calls.contains("codex plugin add nuphy-codex@local"));
}

#[test]
fn update_and_removal_are_scoped_to_the_nuphy_plugin() {
    let fixture = Fixture::new();
    fixture.install();
    let plugin_v2 = fixture._temp.path().join("plugin-v2");
    copy_plugin_fixture(&plugin_v2);

    let update = fixture
        .command()
        .args([
            "lifecycle",
            "update",
            "--plugin-root",
            plugin_v2.to_str().unwrap(),
            "--plugin-id",
            "nuphy-codex@local",
        ])
        .output()
        .unwrap();
    assert!(
        update.status.success(),
        "{}",
        String::from_utf8_lossy(&update.stderr)
    );

    let remove = fixture
        .command()
        .args(["lifecycle", "uninstall"])
        .output()
        .unwrap();
    assert!(
        remove.status.success(),
        "{}",
        String::from_utf8_lossy(&remove.stderr)
    );

    let calls = fs::read_to_string(&fixture.command_log).unwrap();
    assert!(calls.contains("codex plugin add nuphy-codex@local"));
    assert!(calls.contains("codex plugin remove nuphy-codex@local"));
    assert!(!calls.to_ascii_lowercase().contains("zectrix"));
    assert_eq!(
        fs::read_to_string(&fixture.other_product_state).unwrap(),
        "leave-me-alone"
    );
    assert_eq!(
        fs::read_to_string(&fixture.plugin_state).unwrap(),
        "codex-zectrix-dashboard@codex-zectrix-dashboard\n"
    );
    assert!(!fixture.data_dir.join("lifecycle.json").exists());
    assert!(!fixture.data_dir.join("hardware-health.json").exists());
    assert!(
        !fixture
            .launch_agents_dir
            .join("com.barrybarrywu.nuphy-codex.plist")
            .exists()
    );
}

#[test]
fn diagnostics_report_every_health_surface_without_private_codex_content() {
    let fixture = Fixture::new();
    fixture.install();
    fs::write(
        fixture.data_dir.join("hardware-health.json"),
        r#""healthy""#,
    )
    .unwrap();
    let private_values = [
        "private prompt",
        "private assistant prose",
        "/private/transcript.jsonl",
        "private tool output",
    ];
    let mut hook = fixture
        .command()
        .args(["hook", "--status"])
        .arg(fixture.data_dir.join("status.json"))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .spawn()
        .unwrap();
    serde_json::to_writer(
        hook.stdin.take().unwrap(),
        &serde_json::json!({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-1",
            "turn_id": "turn-1",
            "prompt": private_values[0],
            "last_assistant_message": private_values[1],
            "transcript_path": private_values[2],
            "tool_response": private_values[3]
        }),
    )
    .unwrap();
    let output = hook.wait_with_output().unwrap();
    assert!(output.status.success());

    let output = fixture.command().arg("diagnostics").output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let diagnostics = String::from_utf8([output.stdout, output.stderr].concat()).unwrap();
    for field in [
        "hook_ownership=owned",
        "durable_status=healthy",
        "companion=running",
        "keyboard_discovery=air65-v3",
        "protocol_health=healthy",
        "verified_transport=wired-usb",
        "aggregate_state=Execution",
    ] {
        assert!(
            diagnostics.contains(field),
            "missing {field}: {diagnostics}"
        );
    }
    for private in private_values {
        assert!(!diagnostics.contains(private));
    }
}

#[test]
fn removal_refuses_to_forget_a_companion_that_did_not_stop() {
    let fixture = Fixture::new();
    fixture.install();
    executable(
        fixture.launchctl.clone(),
        "#!/bin/sh\nif [ \"${1:-}\" = bootout ]; then exit 1; fi\nif [ \"${1:-}\" = print ]; then printf 'state = running\\n'; exit 0; fi\nexit 0\n",
    );

    let output = fixture
        .command()
        .args(["lifecycle", "uninstall"])
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(fixture.data_dir.join("lifecycle.json").exists());
    assert!(
        fixture
            .launch_agents_dir
            .join("com.barrybarrywu.nuphy-codex.plist")
            .exists()
    );
    assert!(
        fs::read_to_string(&fixture.plugin_state)
            .unwrap()
            .contains("nuphy-codex@local")
    );
}

#[test]
fn diagnostics_report_all_surfaces_when_not_installed() {
    let fixture = Fixture::new();

    let output = fixture.command().arg("diagnostics").output().unwrap();
    assert!(output.status.success());
    let diagnostics = String::from_utf8(output.stdout).unwrap();
    for field in [
        "hook_ownership=not-installed",
        "durable_status=not-installed",
        "companion=not-installed",
        "keyboard_discovery=unavailable",
        "protocol_health=unavailable",
        "verified_transport=unavailable",
        "aggregate_state=unavailable",
    ] {
        assert!(
            diagnostics.contains(field),
            "missing {field}: {diagnostics}"
        );
    }
}

fn copy_plugin_fixture(destination: &Path) {
    fs::create_dir_all(destination.join(".codex-plugin")).unwrap();
    fs::create_dir_all(destination.join("hooks")).unwrap();
    fs::create_dir_all(destination.join("bin")).unwrap();
    fs::copy(
        "plugin/.codex-plugin/plugin.json",
        destination.join(".codex-plugin/plugin.json"),
    )
    .unwrap();
    fs::copy(
        "plugin/hooks/hooks.json",
        destination.join("hooks/hooks.json"),
    )
    .unwrap();
    fs::copy(
        env!("CARGO_BIN_EXE_nuphy-codex"),
        destination.join("bin/nuphy-codex"),
    )
    .unwrap();
}

fn executable(path: PathBuf, contents: &str) -> PathBuf {
    fs::write(&path, contents).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}
