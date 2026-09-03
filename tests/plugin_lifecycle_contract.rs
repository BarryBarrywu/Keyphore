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
    hook_trust: PathBuf,
    hook_disabled: PathBuf,
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
        let hook_trust = temp.path().join("hook-trust");
        let hook_disabled = temp.path().join("hook-disabled");
        fs::write(
            &plugin_state,
            "keyphore@local\ncodex-zectrix-dashboard@codex-zectrix-dashboard\n",
        )
        .unwrap();
        let launchctl = executable(
            temp.path().join("launchctl"),
            "#!/bin/sh\nprintf 'launchctl' >> \"$KEYPHORE_TEST_COMMAND_LOG\"\nprintf ' %s' \"$@\" >> \"$KEYPHORE_TEST_COMMAND_LOG\"\nprintf '\\n' >> \"$KEYPHORE_TEST_COMMAND_LOG\"\nif [ \"${1:-}\" = print ]; then printf 'state = running\\n'; fi\nexit 0\n",
        );
        let codex = executable(
            temp.path().join("codex"),
            r#"#!/bin/sh
printf 'codex' >> "$KEYPHORE_TEST_COMMAND_LOG"
printf ' %s' "$@" >> "$KEYPHORE_TEST_COMMAND_LOG"
printf '\n' >> "$KEYPHORE_TEST_COMMAND_LOG"
if [ "${1:-}" = app-server ]; then
  [ "${KEYPHORE_TEST_APP_SERVER_DESCENDANT:-}" = 1 ] && /bin/sleep 30 &
  read -r initialize
  printf '%s\n' '{"id":1,"result":{"userAgent":"keyphore-test/0.146.1"}}'
  read -r initialized
  while read -r request; do
    printf '%s\n' "$request" >> "$KEYPHORE_TEST_COMMAND_LOG"
    request_id=$(printf '%s\n' "$request" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    if printf '%s' "$request" | grep -q 'config/batchWrite'; then
      touch "$KEYPHORE_TEST_HOOK_TRUST"
      if printf '%s' "$request" | grep -q '"enabled":false'; then
        touch "$KEYPHORE_TEST_HOOK_DISABLED"
      else
        rm -f "$KEYPHORE_TEST_HOOK_DISABLED"
      fi
      printf '{"id":%s,"result":{}}\n' "$request_id"
      continue
    fi
    trust=untrusted
    [ -f "$KEYPHORE_TEST_HOOK_TRUST" ] && trust=trusted
    enabled=true
    [ -f "$KEYPHORE_TEST_HOOK_DISABLED" ] && enabled=false
    root=$(printf '%s\n' "$request" | sed -n 's/.*"cwds":\["\([^"]*\)"\].*/\1/p')
    printf '{"id":%s,"result":{"data":[{"cwd":"fixture","hooks":[' "$request_id"
    first=true
    for event in permissionRequest postToolUse sessionEnd sessionStart stop subagentStart subagentStop userPromptSubmit; do
      [ "$first" = true ] || printf ','
      first=false
      case "$event" in
        permissionRequest) hash=5f25dca9d0ce796a5c7169e57b0fd97b90af4a3fe4329fba791a35aff00fd321 ;;
        postToolUse) hash=7cc58a7a6b7d62914e65120af0b388a61824fa237d8bcdff2d0e8f2f86dcd49f ;;
        sessionEnd) hash=45290ede59950ec464758a3b5f3aca05bc0184a0f456a2dee6f2ca87a65334c9 ;;
        sessionStart) hash=8d0997952af595e40966d18a4b970ddfde9b1082c99d154374e209c4723d9b75 ;;
        stop) hash=e20bbf3639086f8545a28998eac049fba54d63f8fb0b5876e0b43d6f1f0cd34d ;;
        subagentStart) hash=01946b08cd49609fe0cc4a8e43959cd3ebf29ab011278f51d9f77abdbd032a98 ;;
        subagentStop) hash=36375c4c50d15317921135227d6c423f134853c725df334433a38f47fe918c40 ;;
        userPromptSubmit) hash=af395f0d95e15ee1a97f0437eedb1859cdea89b94225d88ba706619e661b9a20 ;;
      esac
      if [ "${KEYPHORE_TEST_BAD_HOOK_HASH:-}" = 1 ] && [ "$event" = stop ]; then
        hash=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      fi
      printf '{"key":"keyphore@local:hooks/hooks.json:%s:0:0","eventName":"%s","handlerType":"command","executionMode":"sync","matcher":null,"command":"\\\"%s/bin/keyphore\\\" hook","timeoutSec":1,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"%s/hooks/hooks.json","pluginId":"keyphore@local","enabled":%s,"isManaged":false,"currentHash":"sha256:%s","trustStatus":"%s"}' "$event" "$event" "$root" "$root" "$enabled" "$hash" "$trust"
    done
    printf '],"warnings":[],"errors":[]} ]}}\n'
  done
  exit 0
fi
if [ "${1:-}" = plugin ] && [ "${2:-}" = list ]; then
  printf '%s\n' '{"installed":[{"pluginId":"keyphore@local","enabled":true},{"pluginId":"codex-zectrix-dashboard@codex-zectrix-dashboard","enabled":true}]}'
elif [ "${1:-}" = plugin ] && [ "${2:-}" = add ]; then
  /usr/bin/grep -Fqx "$3" "$KEYPHORE_TEST_PLUGIN_STATE" || printf '%s\n' "$3" >> "$KEYPHORE_TEST_PLUGIN_STATE"
elif [ "${1:-}" = plugin ] && [ "${2:-}" = remove ]; then
  /usr/bin/grep -Fvx "$3" "$KEYPHORE_TEST_PLUGIN_STATE" > "$KEYPHORE_TEST_PLUGIN_STATE.tmp"
  /bin/mv "$KEYPHORE_TEST_PLUGIN_STATE.tmp" "$KEYPHORE_TEST_PLUGIN_STATE"
fi
exit 0
"#,
        );
        let other_product_state = temp.path().join("zectrix-state.json");
        fs::write(&other_product_state, "leave-me-alone").unwrap();
        Self {
            data_dir: temp.path().join("keyphore-data"),
            launch_agents_dir: temp.path().join("LaunchAgents"),
            launchctl,
            codex,
            command_log,
            plugin_state,
            hook_trust,
            hook_disabled,
            plugin_root,
            other_product_state,
            _temp: temp,
        }
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_keyphore"));
        command
            .env("KEYPHORE_DATA_DIR", &self.data_dir)
            .env("KEYPHORE_LAUNCH_AGENTS_DIR", &self.launch_agents_dir)
            .env("KEYPHORE_LAUNCHCTL_BIN", &self.launchctl)
            .env("KEYPHORE_CODEX_BIN", &self.codex)
            .env("KEYPHORE_LAUNCH_DOMAIN", "gui/501")
            .env("KEYPHORE_TEST_COMMAND_LOG", &self.command_log);
        command
            .env("KEYPHORE_TEST_PLUGIN_STATE", &self.plugin_state)
            .env("KEYPHORE_TEST_HOOK_TRUST", &self.hook_trust)
            .env("KEYPHORE_TEST_HOOK_DISABLED", &self.hook_disabled);
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
                "keyphore@local",
            ])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn trust_hooks(&self) {
        let output = self
            .command()
            .args(["lifecycle", "trust-hooks"])
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
    assert!(state.contains("keyphore@local"));
    assert!(!state.to_ascii_lowercase().contains("zectrix"));
    let plist = fs::read_to_string(
        fixture
            .launch_agents_dir
            .join("com.barrybarrywu.keyphore.plist"),
    )
    .unwrap();
    assert!(plist.contains("plugin-v1/bin/keyphore"));
    let calls = fs::read_to_string(&fixture.command_log).unwrap();
    assert!(calls.contains("codex plugin add keyphore@local"));
}

#[test]
fn explicit_trust_reviews_and_trusts_only_the_owned_hooks() {
    let fixture = Fixture::new();

    let output = fixture
        .command()
        .args([
            "lifecycle",
            "install",
            "--plugin-root",
            fixture.plugin_root.to_str().unwrap(),
            "--plugin-id",
            "keyphore@local",
        ])
        .output()
        .unwrap();

    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("hook_trust_review_required=true"));
    let calls = fs::read_to_string(&fixture.command_log).unwrap();
    assert!(calls.contains("hooks/list"));
    assert!(!calls.contains("config/batchWrite"));

    let output = fixture
        .command()
        .args(["lifecycle", "trust-hooks"])
        .output()
        .unwrap();
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("hook_trust=trusted"));
    let calls = fs::read_to_string(&fixture.command_log).unwrap();
    assert!(calls.contains("config/batchWrite"));
    assert!(
        !calls
            .to_ascii_lowercase()
            .contains("zectrix-dashboard:hooks")
    );
}

#[test]
fn explicit_trust_rejects_a_modified_reviewed_hash() {
    let fixture = Fixture::new();
    fixture.install();

    let output = fixture
        .command()
        .env("KEYPHORE_TEST_BAD_HOOK_HASH", "1")
        .args(["lifecycle", "trust-hooks"])
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(!fixture.hook_trust.exists());
}

#[test]
fn diagnostics_refuse_to_report_runtime_ready_before_explicit_trust() {
    let fixture = Fixture::new();
    fixture.install();

    let output = fixture.command().arg("diagnostics").output().unwrap();

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("hook_trust=untrusted"));
}

#[test]
fn app_server_descendants_cannot_hold_lifecycle_cleanup_open() {
    let fixture = Fixture::new();
    let started = std::time::Instant::now();

    let output = fixture
        .command()
        .env("KEYPHORE_TEST_APP_SERVER_DESCENDANT", "1")
        .args([
            "lifecycle",
            "install",
            "--plugin-root",
            fixture.plugin_root.to_str().unwrap(),
            "--plugin-id",
            "keyphore@local",
        ])
        .output()
        .unwrap();

    assert!(output.status.success());
    assert!(started.elapsed() < std::time::Duration::from_secs(5));
}

#[test]
fn update_and_removal_are_scoped_to_the_keyphore_plugin() {
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
            "keyphore@local",
        ])
        .output()
        .unwrap();
    assert!(
        update.status.success(),
        "{}",
        String::from_utf8_lossy(&update.stderr)
    );
    fs::write(fixture.data_dir.join("hook-events.jsonl"), "audit\n").unwrap();

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
    assert!(calls.contains("codex plugin add keyphore@local"));
    assert!(calls.contains("codex plugin remove keyphore@local"));
    assert!(!calls.to_ascii_lowercase().contains("zectrix"));
    assert_eq!(
        fs::read_to_string(&fixture.other_product_state).unwrap(),
        "leave-me-alone"
    );
    assert_eq!(
        fs::read_to_string(&fixture.plugin_state).unwrap(),
        "codex-zectrix-dashboard@codex-zectrix-dashboard\n"
    );
    record_parity_contract(
        "managed-removal",
        serde_json::json!({
            "owned_plugin_present": fs::read_to_string(&fixture.plugin_state).unwrap().lines().any(|line| line == "keyphore@local"),
            "other_plugin_preserved": fs::read_to_string(&fixture.other_product_state).unwrap() == "leave-me-alone"
                && fs::read_to_string(&fixture.plugin_state).unwrap().contains("codex-zectrix-dashboard@codex-zectrix-dashboard"),
            "owned_hooks_disabled": fixture.hook_disabled.exists(),
        }),
    );
    assert!(!fixture.data_dir.join("lifecycle.json").exists());
    assert!(!fixture.data_dir.join("hook-events.jsonl").exists());
    assert!(fixture.hook_disabled.exists());
    assert!(!fixture.data_dir.join("hardware-health.json").exists());
    assert!(
        !fixture
            .launch_agents_dir
            .join("com.barrybarrywu.keyphore.plist")
            .exists()
    );
}

#[test]
fn diagnostics_report_every_health_surface_without_private_codex_content() {
    let fixture = Fixture::new();
    fixture.install();
    fixture.trust_hooks();
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
        "hook_trust=trusted",
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
    if let Ok(directory) = std::env::var("KEYPHORE_PARITY_OUTPUT") {
        fs::write(
            Path::new(&directory).join("rust-diagnostic-output.txt"),
            &diagnostics,
        )
        .unwrap();
    }
    record_parity_contract(
        "healthy-diagnostics",
        serde_json::json!({
            "hooks_trusted": diagnostics.lines().any(|line| line == "hook_trust=trusted"),
            "companion_running": diagnostics.lines().any(|line| line == "companion=running"),
            "keyboard_connected": diagnostics.lines().any(|line| line == "keyboard_discovery=air65-v3"),
            "protocol_healthy": diagnostics.lines().any(|line| line == "protocol_health=healthy"),
            "private_content_absent": private_values.iter().all(|value| !diagnostics.contains(value)),
        }),
    );
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
            .join("com.barrybarrywu.keyphore.plist")
            .exists()
    );
    assert!(
        fs::read_to_string(&fixture.plugin_state)
            .unwrap()
            .contains("keyphore@local")
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
        "hook_trust=not-installed",
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
        env!("CARGO_BIN_EXE_keyphore"),
        destination.join("bin/keyphore"),
    )
    .unwrap();
}

fn executable(path: PathBuf, contents: &str) -> PathBuf {
    fs::write(&path, contents).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn record_parity_contract(name: &str, observed: serde_json::Value) {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/swift-parity.json")).unwrap();
    assert_eq!(observed, fixture["contracts"][name]);
    if let Ok(directory) = std::env::var("KEYPHORE_PARITY_OUTPUT") {
        fs::write(
            Path::new(&directory).join(format!("rust-{name}.json")),
            serde_json::to_vec_pretty(&observed).unwrap(),
        )
        .unwrap();
    }
}
