use nuphy_codex::companion::{
    Companion, HealthAwareNuPhyIoAdapter, LightingCommand, NuPhyIoAdapter,
};
use nuphy_codex::hook::handle_user_prompt_submit;
use nuphy_codex::status::DurableStatusStore;
use std::time::Duration;

#[derive(Default)]
struct FakeNuPhyIo {
    commands: Vec<LightingCommand>,
    displayed: Option<LightingCommand>,
    health_checks: usize,
}

impl NuPhyIoAdapter for FakeNuPhyIo {
    fn apply(&mut self, command: LightingCommand) -> anyhow::Result<()> {
        self.commands.push(command);
        self.displayed = Some(command);
        Ok(())
    }
}

impl HealthAwareNuPhyIoAdapter for FakeNuPhyIo {
    fn displays(&mut self, command: LightingCommand) -> anyhow::Result<bool> {
        self.health_checks += 1;
        Ok(self.displayed == Some(command))
    }
}

struct DisconnectedNuPhyIo;

impl NuPhyIoAdapter for DisconnectedNuPhyIo {
    fn apply(&mut self, _command: LightingCommand) -> anyhow::Result<()> {
        anyhow::bail!("keyboard disconnected")
    }
}

#[test]
fn reconnect_replays_the_aggregate_state_from_durable_status() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle_user_prompt_submit(
        r#"{"hook_event_name":"UserPromptSubmit","session_id":"session-7","turn_id":"turn-1"}"#,
        &store,
        Duration::from_millis(100),
    )
    .unwrap();
    let mut companion = Companion::default();
    let mut first_connection = FakeNuPhyIo::default();
    companion.sync(&store, &mut first_connection).unwrap();

    let mut reconnected_keyboard = FakeNuPhyIo::default();
    companion
        .device_reconnected(&store, &mut reconnected_keyboard)
        .unwrap();

    assert_eq!(
        reconnected_keyboard.commands,
        [LightingCommand::BlueExecution]
    );
}

#[test]
fn process_restart_reconstructs_and_reapplies_durable_status() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle_user_prompt_submit(
        r#"{"hook_event_name":"UserPromptSubmit","session_id":"session-7","turn_id":"turn-1"}"#,
        &store,
        Duration::from_millis(100),
    )
    .unwrap();

    let mut first_keyboard = FakeNuPhyIo::default();
    Companion::default()
        .sync(&store, &mut first_keyboard)
        .unwrap();
    let mut keyboard_after_restart = FakeNuPhyIo::default();
    Companion::default()
        .sync(&store, &mut keyboard_after_restart)
        .unwrap();

    assert_eq!(
        keyboard_after_restart.commands,
        [LightingCommand::BlueExecution]
    );
}

#[test]
fn disconnect_does_not_rewrite_durable_status_or_block_later_hooks() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle_user_prompt_submit(
        r#"{"hook_event_name":"UserPromptSubmit","session_id":"session-7","turn_id":"turn-1"}"#,
        &store,
        Duration::from_millis(100),
    )
    .unwrap();
    let status_before_disconnect = store.load().unwrap();

    assert!(
        Companion::default()
            .device_reconnected(&store, &mut DisconnectedNuPhyIo)
            .is_err()
    );
    assert_eq!(store.load().unwrap(), status_before_disconnect);

    handle_user_prompt_submit(
        r#"{"hook_event_name":"UserPromptSubmit","session_id":"session-8","turn_id":"turn-1"}"#,
        &store,
        Duration::from_millis(100),
    )
    .unwrap();
    assert_eq!(store.load().unwrap().owners.len(), 2);
}

#[test]
fn health_check_does_not_rewrite_an_already_correct_effect() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    let mut companion = Companion::default();
    let mut keyboard = FakeNuPhyIo::default();
    companion.sync(&store, &mut keyboard).unwrap();

    companion.health_check(&store, &mut keyboard).unwrap();

    assert_eq!(keyboard.health_checks, 1);
    assert_eq!(keyboard.commands, [LightingCommand::SignalOff]);
}

#[test]
fn health_check_reapplies_the_aggregate_state_after_signal_surface_state_loss() {
    let directory = tempfile::tempdir().unwrap();
    let store = DurableStatusStore::new(directory.path().join("status.json"));
    handle_user_prompt_submit(
        r#"{"hook_event_name":"UserPromptSubmit","session_id":"session-7","turn_id":"turn-1"}"#,
        &store,
        Duration::from_millis(100),
    )
    .unwrap();
    let mut companion = Companion::default();
    let mut keyboard = FakeNuPhyIo::default();
    companion.sync(&store, &mut keyboard).unwrap();
    keyboard.displayed = Some(LightingCommand::SignalOff);

    companion.health_check(&store, &mut keyboard).unwrap();

    assert_eq!(keyboard.health_checks, 1);
    assert_eq!(
        keyboard.commands,
        [
            LightingCommand::BlueExecution,
            LightingCommand::BlueExecution
        ]
    );
}
