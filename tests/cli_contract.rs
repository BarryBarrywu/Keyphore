use assert_cmd::Command;
use predicates::prelude::*;
use std::fs;
use std::os::unix::fs::PermissionsExt;

#[test]
fn diagnostic_is_directly_executable_and_requires_an_explicit_lighting_flag() {
    let mut command = Command::cargo_bin("nuphy-codex").unwrap();
    command.args(["diagnose", "--help"]);

    command.assert().success().stdout(
        predicate::str::contains("Discover the verified Air65 V3")
            .and(predicate::str::contains("--exercise"))
            .and(predicate::str::contains(
                "execution, attention, completion, and signal-off",
            ))
            .and(predicate::str::contains(
                "No lighting report is sent unless",
            )),
    );
}

#[test]
fn diagnostics_refuse_to_race_the_installed_companion() {
    let directory = tempfile::tempdir().unwrap();
    let launchctl = directory.path().join("launchctl");
    fs::write(
        &launchctl,
        "#!/bin/sh\nif [ \"${1:-}\" = print ]; then printf 'state = running\\n'; fi\n",
    )
    .unwrap();
    fs::set_permissions(&launchctl, fs::Permissions::from_mode(0o755)).unwrap();
    for arguments in [vec!["diagnose"], vec!["diagnose", "--exercise"]] {
        let mut command = Command::cargo_bin("nuphy-codex").unwrap();
        command
            .args(arguments)
            .env("NUPHY_CODEX_LAUNCHCTL_BIN", &launchctl)
            .env("NUPHY_CODEX_LAUNCH_DOMAIN", "gui/501");

        command.assert().failure().stderr(predicate::str::contains(
            "stop the installed companion before diagnosing the keyboard",
        ));
    }
}

#[test]
fn hook_and_companion_are_directly_executable() {
    for subcommand in ["hook", "companion"] {
        let mut command = Command::cargo_bin("nuphy-codex").unwrap();
        command.args([subcommand, "--help"]);

        command
            .assert()
            .success()
            .stdout(predicate::str::contains("--status"));
    }
}

#[test]
fn hook_persists_without_a_running_companion_or_keyboard() {
    let directory = tempfile::tempdir().unwrap();
    let status = directory.path().join("status.json");
    let mut command = Command::cargo_bin("nuphy-codex").unwrap();
    command
        .args(["hook", "--status"])
        .arg(&status)
        .write_stdin(
            r#"{"hook_event_name":"UserPromptSubmit","session_id":"session-1","turn_id":"turn-1","prompt":"secret"}"#,
        );

    command.assert().success().stdout("");

    let persisted = std::fs::read_to_string(status).unwrap();
    assert!(persisted.contains("session-1"));
    assert!(!persisted.contains("secret"));
}

#[test]
fn hook_accepts_permission_requests_without_a_running_companion_or_keyboard() {
    let directory = tempfile::tempdir().unwrap();
    let status = directory.path().join("status.json");
    let mut command = Command::cargo_bin("nuphy-codex").unwrap();
    command
        .args(["hook", "--status"])
        .arg(&status)
        .write_stdin(
            r#"{"hook_event_name":"PermissionRequest","session_id":"session-1","agent_id":"agent-1","turn_id":"turn-1","tool_input":"secret"}"#,
        );

    command.assert().success().stdout("");

    let persisted = std::fs::read_to_string(status).unwrap();
    assert!(persisted.contains("attention"));
    assert!(!persisted.contains("secret"));
}
