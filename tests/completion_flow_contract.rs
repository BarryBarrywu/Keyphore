use std::time::Duration;
use std::{fs, vec};

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

fn event(name: &str, session: &str, turn: &str) -> String {
    format!(r#"{{"hook_event_name":"{name}","session_id":"{session}","turn_id":"{turn}"}}"#)
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
fn main_stop_shows_completion_for_five_seconds_then_turns_the_signal_off() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(&event("UserPromptSubmit", "session-1", "turn-1"), &store, 0);
    handle(&event("Stop", "session-1", "turn-1"), &store, 100);

    let mut companion = Companion::default();
    let mut adapter = FakeNuPhyIo::default();
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(100))
        .unwrap();
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(5_099))
        .unwrap();
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(5_100))
        .unwrap();

    assert_eq!(
        adapter.commands,
        [LightingCommand::GreenCompletion, LightingCommand::SignalOff,]
    );
}

#[test]
fn execution_outranks_another_sessions_completion_after_its_window_expires() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(
        &event("UserPromptSubmit", "session-complete", "turn-1"),
        &store,
        0,
    );
    handle(&event("Stop", "session-complete", "turn-1"), &store, 100);
    handle(
        &event("UserPromptSubmit", "session-executing", "turn-1"),
        &store,
        200,
    );

    let mut companion = Companion::default();
    let mut adapter = FakeNuPhyIo::default();
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(200))
        .unwrap();
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(5_100))
        .unwrap();

    assert_eq!(adapter.commands, [LightingCommand::BlueExecution]);
    let remaining = store.load().unwrap().owners;
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].id.session_id, "session-executing");
}

#[test]
fn session_end_removes_the_session_and_all_of_its_owners() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(&event("UserPromptSubmit", "session-1", "turn-1"), &store, 0);
    handle(
        r#"{"hook_event_name":"PermissionRequest","session_id":"session-1","agent_id":"agent-1","turn_id":"turn-1"}"#,
        &store,
        100,
    );

    handle(
        r#"{"hook_event_name":"SessionEnd","session_id":"session-1"}"#,
        &store,
        200,
    );

    let mut adapter = FakeNuPhyIo::default();
    Companion::default()
        .sync_at(&store, &mut adapter, Timestamp::from_millis(200))
        .unwrap();
    assert_eq!(adapter.commands, [LightingCommand::SignalOff]);
    assert!(store.load().unwrap().owners.is_empty());
}

#[test]
fn a_stale_completion_timeout_cannot_clear_new_execution_for_the_same_owner() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(&event("UserPromptSubmit", "session-1", "turn-1"), &store, 0);
    handle(&event("Stop", "session-1", "turn-1"), &store, 100);

    let mut companion = Companion::default();
    let stale_timeout = companion
        .pending_completion_expiries(&store)
        .unwrap()
        .remove(0);
    handle(
        &event("UserPromptSubmit", "session-1", "turn-2"),
        &store,
        1_000,
    );

    let mut adapter = FakeNuPhyIo::default();
    companion
        .handle_completion_timeout_at(
            &store,
            &mut adapter,
            stale_timeout,
            Timestamp::from_millis(5_100),
        )
        .unwrap();

    assert_eq!(adapter.commands, [LightingCommand::BlueExecution]);
}

#[test]
fn failed_tool_data_and_assistant_prose_do_not_create_a_failure_signal() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(
        r#"{"hook_event_name":"PostToolUse","session_id":"session-1","turn_id":"turn-1","tool_response":{"success":false,"output":"private failed tool output"}}"#,
        &store,
        0,
    );

    let mut companion = Companion::default();
    let mut adapter = FakeNuPhyIo::default();
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(0))
        .unwrap();
    handle(
        r#"{"hook_event_name":"Stop","session_id":"session-1","turn_id":"turn-1","last_assistant_message":"the task failed"}"#,
        &store,
        100,
    );
    companion
        .sync_at(&store, &mut adapter, Timestamp::from_millis(100))
        .unwrap();

    assert_eq!(
        adapter.commands,
        vec![
            LightingCommand::BlueExecution,
            LightingCommand::GreenCompletion,
        ]
    );
    let persisted = fs::read_to_string(store.path()).unwrap();
    assert!(!persisted.contains("private failed tool output"));
    assert!(!persisted.contains("the task failed"));
}
