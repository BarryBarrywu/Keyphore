use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail, ensure};
use fs2::FileExt;
use serde::Serialize;
use serde_json::Value;

use crate::status::{DurableStatusStore, Signal, SignalOwnerId, Timestamp};

const ATTENTION_LIFETIME: Duration = Duration::from_secs(60 * 60);
const COMPLETION_LIFETIME: Duration = Duration::from_secs(5);
const MAX_AUDIT_BYTES: u64 = 256 * 1024;
const MAX_AUDIT_FIELD_CHARS: usize = 128;

#[derive(Serialize)]
struct HookAuditRecord {
    hook_event_name: Option<String>,
    session_id: Option<String>,
    agent_id: Option<String>,
    turn_id: Option<String>,
    received_at: Timestamp,
}

pub fn append_hook_audit(
    input: &str,
    path: &Path,
    lock_timeout: Duration,
    received_at: Timestamp,
) -> Result<()> {
    let input: Value = serde_json::from_str(input).context("Hook input is not valid JSON")?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).context("failed to create Hook audit directory")?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .read(true)
        .append(true)
        .open(path)
        .context("failed to open Hook audit")?;
    let deadline = Instant::now() + lock_timeout;
    loop {
        match file.try_lock_exclusive() {
            Ok(()) => break,
            Err(error) if error.kind() == ErrorKind::WouldBlock && Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(1));
            }
            Err(error) => return Err(error).context("failed to lock Hook audit"),
        }
    }
    let record = serde_json::to_vec(&HookAuditRecord {
        hook_event_name: bounded_field(&input, "hook_event_name"),
        session_id: bounded_field(&input, "session_id"),
        agent_id: bounded_field(&input, "agent_id"),
        turn_id: bounded_field(&input, "turn_id"),
        received_at,
    })?;
    let record_len = u64::try_from(record.len())?.saturating_add(1);
    ensure!(
        record_len <= MAX_AUDIT_BYTES,
        "Hook audit record is too large"
    );
    if file.metadata()?.len().saturating_add(record_len) > MAX_AUDIT_BYTES {
        file.set_len(0)?;
    }
    file.write_all(&record)?;
    file.write_all(b"\n")?;
    FileExt::unlock(&file)?;
    Ok(())
}

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
    let agent_id = match event_name {
        "SubagentStart" | "SubagentStop" => field(&input, "agent_id")?,
        "PermissionRequest" | "PostToolUse" => input
            .get("agent_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .unwrap_or("main"),
        _ => "main",
    };
    let owner_id = SignalOwnerId {
        product: "codex".into(),
        session_id: field(&input, "session_id")?.into(),
        agent_id: agent_id.into(),
    };
    if matches!(event_name, "SessionStart" | "SessionEnd") {
        return store.remove_session("codex", &owner_id.session_id, lock_timeout);
    }
    if event_name == "SubagentStop" {
        return store.remove_owner_for_turn(&owner_id, field(&input, "turn_id")?, lock_timeout);
    }
    if event_name == "Stop" {
        return store
            .record_signal(
                owner_id,
                field(&input, "turn_id")?.into(),
                Signal::Completion,
                Some(now.saturating_add(COMPLETION_LIFETIME)),
                lock_timeout,
            )
            .map(|_| ());
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
        "PostToolUse" | "SubagentStart" => (Signal::Execution, None),
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

fn bounded_field(input: &Value, name: &str) -> Option<String> {
    input
        .get(name)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(|value| value.chars().take(MAX_AUDIT_FIELD_CHARS).collect())
}
