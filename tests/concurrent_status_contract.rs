use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

use nuphy_codex::companion::{Companion, LightingCommand, NuPhyIoAdapter};
use nuphy_codex::hook::handle_codex_event_at;
use nuphy_codex::status::{DurableStatusStore, Signal, SignalOwnerId, Timestamp};
use nuphy_codex::status_core::{AggregateState, StatusCore};

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

fn owner(session: &str) -> SignalOwnerId {
    SignalOwnerId {
        product: "codex".into(),
        session_id: session.into(),
        agent_id: "main".into(),
    }
}

#[test]
fn subagent_lifecycle_keeps_the_main_owner_and_removes_only_the_child() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(
        &event("UserPromptSubmit", "session-1", None, "turn-1"),
        &store,
        0,
    );
    handle(
        &event("SubagentStart", "session-1", Some("agent-1"), "turn-1"),
        &store,
        10,
    );

    let owners = store.load().unwrap().owners;
    assert_eq!(owners.len(), 2);
    assert!(owners.iter().any(|owner| owner.id.agent_id == "main"));
    assert!(owners.iter().any(|owner| owner.id.agent_id == "agent-1"));

    handle(
        &event("SubagentStop", "session-1", Some("agent-1"), "turn-1"),
        &store,
        20,
    );

    let remaining = store.load().unwrap().owners;
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].id.agent_id, "main");
    let mut adapter = FakeNuPhyIo::default();
    Companion::default()
        .sync_at(&store, &mut adapter, Timestamp::from_millis(20))
        .unwrap();
    assert_eq!(adapter.commands, [LightingCommand::BlueExecution]);
}

#[test]
fn events_from_an_older_turn_cannot_overwrite_current_session_facts() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(
        &event("UserPromptSubmit", "session-1", None, "turn-1"),
        &store,
        0,
    );
    handle(
        &event(
            "SubagentStart",
            "session-1",
            Some("current-child"),
            "turn-2",
        ),
        &store,
        10,
    );
    handle(
        &event("UserPromptSubmit", "session-1", None, "turn-2"),
        &store,
        20,
    );
    handle(
        &event(
            "SubagentStart",
            "session-1",
            Some("current-child"),
            "turn-2",
        ),
        &store,
        30,
    );

    for stale_event in [
        event("PermissionRequest", "session-1", None, "turn-1"),
        event("SubagentStart", "session-1", Some("stale-child"), "turn-1"),
        event("SubagentStop", "session-1", Some("current-child"), "turn-1"),
        event("Stop", "session-1", None, "turn-1"),
    ] {
        handle(&stale_event, &store, 40);
    }

    let owners = store.load().unwrap().owners;
    assert_eq!(owners.len(), 2);
    assert!(owners.iter().all(|owner| owner.turn_id == "turn-2"));
    assert!(
        owners
            .iter()
            .any(|owner| owner.id.agent_id == "current-child")
    );
    let mut adapter = FakeNuPhyIo::default();
    Companion::default()
        .sync_at(&store, &mut adapter, Timestamp::from_millis(40))
        .unwrap();
    assert_eq!(adapter.commands, [LightingCommand::BlueExecution]);
}

#[test]
fn aggregate_priority_includes_unmapped_failure_without_hook_inference() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    let now = Timestamp::from_millis(100);
    for (session, signal, expires_at) in [
        (
            "completion",
            Signal::Completion,
            Some(Timestamp::from_millis(1_000)),
        ),
        ("execution", Signal::Execution, None),
        ("failure", Signal::Failure, None),
        (
            "attention",
            Signal::Attention,
            Some(Timestamp::from_millis(1_000)),
        ),
    ] {
        store
            .record_signal(
                owner(session),
                "turn-1".into(),
                signal,
                expires_at,
                Duration::from_millis(100),
            )
            .unwrap();
    }

    assert_eq!(
        StatusCore::reduce_at(&store.load().unwrap(), now),
        AggregateState::Attention
    );
    store
        .remove_owner(&owner("attention"), Duration::from_millis(100))
        .unwrap();
    assert_eq!(
        StatusCore::reduce_at(&store.load().unwrap(), now),
        AggregateState::Failure
    );
    store
        .remove_owner(&owner("failure"), Duration::from_millis(100))
        .unwrap();
    assert_eq!(
        StatusCore::reduce_at(&store.load().unwrap(), now),
        AggregateState::Execution
    );
    store
        .remove_owner(&owner("execution"), Duration::from_millis(100))
        .unwrap();
    assert_eq!(
        StatusCore::reduce_at(&store.load().unwrap(), now),
        AggregateState::Completion
    );
    store
        .remove_owner(&owner("completion"), Duration::from_millis(100))
        .unwrap();
    assert_eq!(
        StatusCore::reduce_at(&store.load().unwrap(), now),
        AggregateState::SignalOff
    );
}

#[test]
fn subagent_events_require_a_distinct_child_identity() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(
        &event("UserPromptSubmit", "session-1", None, "turn-1"),
        &store,
        0,
    );

    for event_name in ["SubagentStart", "SubagentStop"] {
        let result = handle_codex_event_at(
            &event(event_name, "session-1", None, "turn-1"),
            &store,
            Duration::from_millis(100),
            Timestamp::from_millis(10),
        );
        assert!(result.is_err());
    }

    let owners = store.load().unwrap().owners;
    assert_eq!(owners.len(), 1);
    assert_eq!(owners[0].id.agent_id, "main");
}

#[test]
fn main_completion_does_not_replace_child_execution() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(
        &event("UserPromptSubmit", "session-1", None, "turn-1"),
        &store,
        0,
    );
    handle(
        &event("SubagentStart", "session-1", Some("agent-1"), "turn-1"),
        &store,
        10,
    );
    handle(&event("Stop", "session-1", None, "turn-1"), &store, 20);

    let status = store.load().unwrap();
    assert_eq!(status.owners.len(), 2);
    assert!(
        status
            .owners
            .iter()
            .any(|owner| { owner.id.agent_id == "main" && owner.signal == Signal::Completion })
    );
    assert!(
        status
            .owners
            .iter()
            .any(|owner| { owner.id.agent_id == "agent-1" && owner.signal == Signal::Execution })
    );
    let mut adapter = FakeNuPhyIo::default();
    Companion::default()
        .sync_at(&store, &mut adapter, Timestamp::from_millis(20))
        .unwrap();
    assert_eq!(adapter.commands, [LightingCommand::BlueExecution]);
}

#[test]
fn later_lower_priority_events_cannot_hide_another_sessions_attention() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle(
        &event("PermissionRequest", "attention", None, "turn-1"),
        &store,
        0,
    );
    handle(
        &event("UserPromptSubmit", "execution", None, "turn-1"),
        &store,
        10,
    );
    handle(
        &event("UserPromptSubmit", "completion", None, "turn-1"),
        &store,
        20,
    );
    handle(&event("Stop", "completion", None, "turn-1"), &store, 30);

    let mut adapter = FakeNuPhyIo::default();
    Companion::default()
        .sync_at(&store, &mut adapter, Timestamp::from_millis(30))
        .unwrap();
    assert_eq!(adapter.commands, [LightingCommand::OrangeAttention]);
}

#[test]
fn session_cleanup_removes_only_the_matching_session_scope() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    for session in ["session-1", "session-2"] {
        handle(
            &event("UserPromptSubmit", session, None, "turn-1"),
            &store,
            0,
        );
        handle(
            &event("SubagentStart", session, Some("agent-1"), "turn-1"),
            &store,
            10,
        );
    }
    handle(
        r#"{"hook_event_name":"SessionEnd","session_id":"session-1"}"#,
        &store,
        20,
    );

    let status = store.load().unwrap();
    assert_eq!(status.owners.len(), 2);
    assert!(
        status
            .owners
            .iter()
            .all(|owner| owner.id.session_id == "session-2")
    );
    assert_eq!(status.sessions.len(), 1);
    assert_eq!(status.sessions[0].session_id, "session-2");
}

#[test]
fn owner_identity_includes_product_session_and_agent() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    for product in ["codex", "another-product"] {
        let mut id = owner("shared-session");
        id.product = product.into();
        store
            .record_signal(
                id,
                "turn-1".into(),
                Signal::Execution,
                None,
                Duration::from_millis(100),
            )
            .unwrap();
    }

    let owners = store.load().unwrap().owners;
    assert_eq!(owners.len(), 2);
    assert_ne!(owners[0].id, owners[1].id);
}

#[test]
fn concurrent_hooks_finish_with_atomic_aggregate_status_within_the_lock_budget() {
    let directory = tempfile::tempdir().unwrap();
    let status_path = directory.path().join("status.json");
    let barrier = Arc::new(Barrier::new(8));
    let threads: Vec<_> = (0..8)
        .map(|index| {
            let status_path = status_path.clone();
            let barrier = Arc::clone(&barrier);
            thread::spawn(move || {
                let event_name = if index == 0 {
                    "PermissionRequest"
                } else {
                    "UserPromptSubmit"
                };
                let input = event(event_name, &format!("session-{index}"), None, "turn-1");
                barrier.wait();
                let started = Instant::now();
                handle_codex_event_at(
                    &input,
                    &DurableStatusStore::new(status_path),
                    Duration::from_secs(1),
                    Timestamp::from_millis(0),
                )
                .unwrap();
                started.elapsed()
            })
        })
        .collect();

    for thread in threads {
        assert!(thread.join().unwrap() < Duration::from_secs(1));
    }
    let store = DurableStatusStore::new(status_path);
    let status = store.load().unwrap();
    assert_eq!(status.owners.len(), 8);
    let mut adapter = FakeNuPhyIo::default();
    Companion::default()
        .sync_at(&store, &mut adapter, Timestamp::from_millis(0))
        .unwrap();
    assert_eq!(adapter.commands, [LightingCommand::OrangeAttention]);
}
