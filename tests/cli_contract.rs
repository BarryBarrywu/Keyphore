use assert_cmd::Command;
use predicates::prelude::*;

#[test]
fn diagnostic_is_directly_executable_and_requires_an_explicit_lighting_flag() {
    let mut command = Command::cargo_bin("nuphy-codex").unwrap();
    command.args(["diagnose", "--help"]);

    command.assert().success().stdout(
        predicate::str::contains("Discover the verified Air65 V3")
            .and(predicate::str::contains("--exercise"))
            .and(predicate::str::contains(
                "No lighting report is sent unless",
            )),
    );
}
