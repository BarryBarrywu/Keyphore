use std::fs::{self, OpenOptions};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

use fs2::FileExt;
use keyphore::companion::{Companion, LightingCommand, NuPhyIoAdapter, sync_once};
use keyphore::hook::handle_user_prompt_submit;
use keyphore::status::DurableStatusStore;

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

#[test]
fn user_prompt_submit_persists_execution_and_companion_applies_blue() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    let input = r#"{
        "hook_event_name": "UserPromptSubmit",
        "session_id": "session-7",
        "turn_id": "turn-3",
        "prompt": "private prompt text",
        "last_assistant_message": "private assistant prose",
        "transcript_path": "/private/transcript.jsonl",
        "tool_output": "private tool output"
    }"#;

    handle_user_prompt_submit(input, &store, Duration::from_millis(100)).unwrap();

    let persisted = fs::read_to_string(store.path()).unwrap();
    for private_value in [
        "private prompt text",
        "private assistant prose",
        "/private/transcript.jsonl",
        "private tool output",
    ] {
        assert!(!persisted.contains(private_value));
    }

    let mut adapter = FakeNuPhyIo::default();
    sync_once(&store, &mut adapter).unwrap();

    assert_eq!(adapter.commands, [LightingCommand::BlueExecution]);
}

#[test]
fn empty_durable_status_applies_signal_off() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    let mut adapter = FakeNuPhyIo::default();

    sync_once(&store, &mut adapter).unwrap();

    assert_eq!(adapter.commands, [LightingCommand::SignalOff]);
}

#[test]
fn long_lived_companion_does_not_reapply_unchanged_status() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    let mut adapter = FakeNuPhyIo::default();
    let mut companion = Companion::default();

    companion.sync(&store, &mut adapter).unwrap();
    companion.sync(&store, &mut adapter).unwrap();

    assert_eq!(adapter.commands, [LightingCommand::SignalOff]);
}

#[test]
fn hook_updates_from_multiple_owners_remain_atomic() {
    let directory = tempfile::tempdir().unwrap();
    let status_path = directory.path().join("status.json");
    let barrier = Arc::new(Barrier::new(8));
    let threads: Vec<_> = (0..8)
        .map(|owner| {
            let status_path = status_path.clone();
            let barrier = Arc::clone(&barrier);
            thread::spawn(move || {
                barrier.wait();
                let input = format!(
                    r#"{{"hook_event_name":"UserPromptSubmit","session_id":"session-{owner}","turn_id":"turn-1"}}"#
                );
                handle_user_prompt_submit(
                    &input,
                    &DurableStatusStore::new(status_path),
                    Duration::from_secs(1),
                )
                .unwrap();
            })
        })
        .collect();

    for thread in threads {
        thread.join().unwrap();
    }

    let status = DurableStatusStore::new(status_path).load().unwrap();
    assert_eq!(status.owners.len(), 8);
}

#[test]
fn hook_lock_wait_is_bounded() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    let lock = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(directory.path().join("status.lock"))
        .unwrap();
    lock.lock_exclusive().unwrap();

    let started = Instant::now();
    let result = handle_user_prompt_submit(
        r#"{"hook_event_name":"UserPromptSubmit","session_id":"session-1","turn_id":"turn-1"}"#,
        &store,
        Duration::from_millis(30),
    );

    assert!(result.is_err());
    assert!(started.elapsed() < Duration::from_millis(250));
}
