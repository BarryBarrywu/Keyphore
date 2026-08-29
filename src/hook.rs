use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::status::{DurableStatusStore, OwnerStatus, Signal, SignalOwnerId};

pub fn handle_user_prompt_submit(
    input: &str,
    store: &DurableStatusStore,
    lock_timeout: Duration,
) -> Result<()> {
    let input: Value = serde_json::from_str(input).context("Hook input is not valid JSON")?;
    if field(&input, "hook_event_name")? != "UserPromptSubmit" {
        bail!("unsupported Hook event")
    }

    let owner = OwnerStatus {
        id: SignalOwnerId {
            product: "codex".into(),
            session_id: field(&input, "session_id")?.into(),
            agent_id: input
                .get("agent_id")
                .and_then(Value::as_str)
                .unwrap_or("main")
                .into(),
        },
        turn_id: field(&input, "turn_id")?.into(),
        signal: Signal::Execution,
    };
    store.record_execution(owner, lock_timeout)
}

fn field<'a>(input: &'a Value, name: &str) -> Result<&'a str> {
    input
        .get(name)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .with_context(|| format!("Hook input is missing {name}"))
}
