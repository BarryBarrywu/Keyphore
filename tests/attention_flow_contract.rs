use std::time::Duration;

use nuphy_codex::companion::{Companion, LightingCommand, NuPhyIoAdapter};
use nuphy_codex::hook::handle_codex_event_at;
use nuphy_codex::status::{DurableStatusStore, Timestamp};

#[derive(Default)]
struct FakeNuPhyIo {
    commands: Vec<LightingCommand>,
}

impl NuPhyIoAdapter for FakeNuPhyIo {
    fn apply(&mut self, command: LightingCommand) -> anyhow::Result<()> {
        self.commands.push(command);
        Ok(())
    }
}

fn event(name: &str, session: &str, agent: Option<&str>, turn: &str) -> String {
    let agent = agent
        .map(|agent| format!(r#", "agent_id": "{agent}""#))
        .unwrap_or_default();
    format!(r#"{{"hook_event_name":"{name}","session_id":"{session}","turn_id":"{turn}"{agent}}}"#)
}

fn handle(input: &str, store: &DurableStatusStore, now_ms: u64) {
    handle_codex_event_at(
        input,
        store,
        Duration::from_millis(100),
        Timestamp::from_millis(now_ms),
    )
    .unwrap();
}

#[test]
fn permission_request_outranks_execution_then_releases_back_to_execution() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(
        &event("UserPromptSubmit", "session-executing", None, "turn-1"),
        &store,
        0,
    );
    handle(
        &event(
            "PermissionRequest",
            "session-attention",
            Some("agent-7"),
            "turn-1",
        ),
        &store,
        100,
    );

    let mut companion = Companion::default();
    let mut adapter = FakeNuPhyIo::default();
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(100))
        .unwrap();

    handle(
        &event(
            "PostToolUse",
            "session-attention",
            Some("agent-7"),
            "turn-1",
        ),
        &store,
        200,
    );
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(200))
        .unwrap();

    assert_eq!(
        adapter.commands,
        [
            LightingCommand::OrangeAttention,
            LightingCommand::BlueExecution,
        ]
    );
}

#[test]
fn releasing_each_attention_owner_is_independent() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(
        &event("UserPromptSubmit", "session-1", None, "turn-1"),
        &store,
        0,
    );
    for agent in ["agent-1", "agent-2"] {
        handle(
            &event("PermissionRequest", "session-1", Some(agent), "turn-1"),
            &store,
            100,
        );
    }

    let mut companion = Companion::default();
    let mut adapter = FakeNuPhyIo::default();
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(100))
        .unwrap();
    handle(
        &event("PostToolUse", "session-1", Some("agent-1"), "turn-1"),
        &store,
        200,
    );
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(200))
        .unwrap();
    handle(
        &event("SubagentStop", "session-1", Some("agent-2"), "turn-1"),
        &store,
        300,
    );
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(300))
        .unwrap();

    assert_eq!(
        adapter.commands,
        [
            LightingCommand::OrangeAttention,
            LightingCommand::BlueExecution,
        ]
    );
}

#[test]
fn stale_attention_expires_after_one_hour_and_reveals_execution() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(
        &event("UserPromptSubmit", "session-executing", None, "turn-1"),
        &store,
        0,
    );
    handle(
        &event("PermissionRequest", "session-stale", None, "turn-1"),
        &store,
        0,
    );

    let mut companion = Companion::default();
    let mut adapter = FakeNuPhyIo::default();
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(0))
        .unwrap();
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(3_600_000))
        .unwrap();

    assert_eq!(
        adapter.commands,
        [
            LightingCommand::OrangeAttention,
            LightingCommand::BlueExecution,
        ]
    );
    assert!(
        store
            .load()
            .unwrap()
            .owners
            .iter()
            .all(|owner| owner.id.session_id != "session-stale")
    );
}

#[test]
fn stale_timeout_cannot_clear_a_newer_generation_of_the_same_owner() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    let permission = event("PermissionRequest", "session-1", None, "turn-1");
    handle(&permission, &store, 0);

    let mut companion = Companion::default();
    let stale_timeout = companion
        .pending_attention_expiries(&store)
        .unwrap()
        .remove(0);
    handle(&permission, &store, 1_000);

    let mut adapter = FakeNuPhyIo::default();
    companion
        .handle_attention_timeout_at(
            &store,
            &mut adapter,
            stale_timeout,
            Timestamp::from_millis(3_600_000),
        )
        .unwrap();

    assert_eq!(adapter.commands, [LightingCommand::OrangeAttention]);
}

#[test]
fn a_new_prompt_cleans_stale_attention_from_the_same_session() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(
        &event(
            "PermissionRequest",
            "session-1",
            Some("stale-agent"),
            "turn-1",
        ),
        &store,
        0,
    );
    handle(
        &event("UserPromptSubmit", "session-1", None, "turn-2"),
        &store,
        100,
    );

    let mut adapter = FakeNuPhyIo::default();
    Companion::default()
        .sync_at(&store, &mut adapter, Timestamp::from_millis(100))
        .unwrap();

    assert_eq!(adapter.commands, [LightingCommand::BlueExecution]);
}

#[test]
fn stop_releases_only_the_main_owner() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    for session in ["session-1", "session-2"] {
        handle(
            &event("PermissionRequest", session, None, "turn-1"),
            &store,
            0,
        );
    }
    handle(&event("Stop", "session-1", None, "turn-1"), &store, 100);

    let mut adapter = FakeNuPhyIo::default();
    Companion::default()
        .sync_at(&store, &mut adapter, Timestamp::from_millis(100))
        .unwrap();

    assert_eq!(adapter.commands, [LightingCommand::OrangeAttention]);
    assert_eq!(store.load().unwrap().owners.len(), 1);
    assert_eq!(store.load().unwrap().owners[0].id.session_id, "session-2");
}

#[test]
fn session_start_cleans_all_stale_owners_in_that_session() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(
        &event("PermissionRequest", "session-1", Some("agent-1"), "turn-1"),
        &store,
        0,
    );
    handle(
        r#"{"hook_event_name":"SessionStart","session_id":"session-1"}"#,
        &store,
        100,
    );

    let mut adapter = FakeNuPhyIo::default();
    Companion::default()
        .sync_at(&store, &mut adapter, Timestamp::from_millis(100))
        .unwrap();

    assert_eq!(adapter.commands, [LightingCommand::SignalOff]);
}
