use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::status::{DurableStatusStore, Signal, SignalOwnerId, Timestamp};

const ATTENTION_LIFETIME: Duration = Duration::from_secs(60 * 60);

pub fn handle_user_prompt_submit(
    input: &str,
    store: &DurableStatusStore,
    lock_timeout: Duration,
) -> Result<()> {
    let input_value: Value = serde_json::from_str(input).context("Hook input is not valid JSON")?;
    if field(&input_value, "hook_event_name")? != "UserPromptSubmit" {
        bail!("unsupported Hook event")
    }
    handle_codex_event_at(input, store, lock_timeout, Timestamp::now())
}

pub fn handle_codex_event_at(
    input: &str,
    store: &DurableStatusStore,
    lock_timeout: Duration,
    now: Timestamp,
) -> Result<()> {
    let input: Value = serde_json::from_str(input).context("Hook input is not valid JSON")?;
    let event_name = field(&input, "hook_event_name")?;
    let owner_id = SignalOwnerId {
        product: "codex".into(),
        session_id: field(&input, "session_id")?.into(),
        agent_id: input
            .get("agent_id")
            .and_then(Value::as_str)
            .unwrap_or("main")
            .into(),
    };
    if event_name == "SessionStart" {
        return store.remove_session("codex", &owner_id.session_id, lock_timeout);
    }
    if matches!(event_name, "Stop" | "SubagentStop") {
        return store.remove_owner(&owner_id, lock_timeout);
    }
    if event_name == "UserPromptSubmit" {
        return store.replace_session_with_signal(
            owner_id,
            field(&input, "turn_id")?.into(),
            Signal::Execution,
            lock_timeout,
        );
    }
    let (signal, expires_at) = match event_name {
        "PostToolUse" => (Signal::Execution, None),
        "PermissionRequest" => (
            Signal::Attention,
            Some(now.saturating_add(ATTENTION_LIFETIME)),
        ),
        _ => bail!("unsupported Hook event"),
    };
    store
        .record_signal(
            owner_id,
            field(&input, "turn_id")?.into(),
            signal,
            expires_at,
            lock_timeout,
        )
        .map(|_| ())
}

fn field<'a>(input: &'a Value, name: &str) -> Result<&'a str> {
    input
        .get(name)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .with_context(|| format!("Hook input is missing {name}"))
}
