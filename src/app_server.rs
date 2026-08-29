use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::{Value, json};

const RESPONSE_TIMEOUT: Duration = Duration::from_secs(5);

pub struct AppServerClient {
    program: PathBuf,
}

impl AppServerClient {
    pub fn new(program: impl AsRef<Path>) -> Self {
        Self {
            program: program.as_ref().to_owned(),
        }
    }

    pub fn list_hooks(&self, cwd: &Path) -> Result<Vec<HookMetadata>> {
        let result = self.request("hooks/list", json!({ "cwds": [cwd] }))?;
        let data = result
            .get("data")
            .and_then(Value::as_array)
            .context("Codex hooks/list response is missing data")?;
        let entry = data.first().context("Codex hooks/list response is empty")?;
        if entry
            .get("errors")
            .and_then(Value::as_array)
            .is_some_and(|errors| !errors.is_empty())
        {
            bail!("Codex hooks/list reported an error")
        }
        serde_json::from_value(
            entry
                .get("hooks")
                .cloned()
                .context("Codex hooks/list response is missing hooks")?,
        )
        .context("Codex hooks/list returned invalid hook metadata")
    }

    pub fn trust_hooks(&self, hooks: &[HookMetadata]) -> Result<()> {
        self.configure_hooks(hooks, true)
    }

    pub fn disable_hooks(&self, hooks: &[HookMetadata]) -> Result<()> {
        self.configure_hooks(hooks, false)
    }

    fn configure_hooks(&self, hooks: &[HookMetadata], enabled: bool) -> Result<()> {
        let states = hooks
            .iter()
            .map(|hook| {
                (
                    hook.key.clone(),
                    json!({
                        "enabled": enabled,
                        "trusted_hash": hook.current_hash,
                    }),
                )
            })
            .collect::<serde_json::Map<_, _>>();
        self.request(
            "config/batchWrite",
            json!({
                "edits": [{
                    "keyPath": "hooks.state",
                    "value": states,
                    "mergeStrategy": "upsert"
                }],
                "reloadUserConfig": true
            }),
        )?;
        Ok(())
    }

    fn request(&self, method: &str, params: Value) -> Result<Value> {
        let mut session = AppServerSession::start(&self.program)?;
        session.request(method, params)
    }
}

struct AppServerSession {
    child: Child,
    process_group_id: libc::pid_t,
    stdin: Option<ChildStdin>,
    receiver: Receiver<std::io::Result<String>>,
    reader: Option<JoinHandle<()>>,
}

impl AppServerSession {
    fn start(program: &Path) -> Result<Self> {
        let mut child = Command::new(program)
            .args(["app-server", "--stdio"])
            .process_group(0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .context("failed to start Codex app-server")?;
        let stdin = child
            .stdin
            .take()
            .context("Codex app-server has no stdin")?;
        let stdout = child
            .stdout
            .take()
            .context("Codex app-server has no stdout")?;
        let (sender, receiver) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        let mut session = Self {
            process_group_id: child.id().try_into().unwrap(),
            child,
            stdin: Some(stdin),
            receiver,
            reader: Some(reader),
        };
        session.write(&json!({
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "nuphy-codex",
                    "version": env!("CARGO_PKG_VERSION")
                }
            }
        }))?;
        read_result(&session.receiver, 1)?;
        session.write(&json!({ "method": "initialized" }))?;
        Ok(session)
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value> {
        self.write(&json!({ "id": 2, "method": method, "params": params }))?;
        read_result(&self.receiver, 2)
    }

    fn write(&mut self, message: &Value) -> Result<()> {
        let stdin = self
            .stdin
            .as_mut()
            .context("Codex app-server stdin closed")?;
        serde_json::to_writer(&mut *stdin, message)?;
        stdin.write_all(b"\n")?;
        stdin.flush()?;
        Ok(())
    }
}

impl Drop for AppServerSession {
    fn drop(&mut self) {
        self.stdin.take();
        signal_process_group(self.process_group_id, libc::SIGTERM);
        if !wait_for_exit(&mut self.child, Duration::from_secs(1)) {
            signal_process_group(self.process_group_id, libc::SIGKILL);
        }
        let _ = self.child.wait();
        signal_process_group(self.process_group_id, libc::SIGKILL);
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

fn wait_for_exit(child: &mut Child, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if child.try_wait().ok().flatten().is_some() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn signal_process_group(process_group_id: libc::pid_t, signal: libc::c_int) {
    unsafe {
        libc::kill(-process_group_id, signal);
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HookMetadata {
    pub key: String,
    pub event_name: String,
    pub handler_type: String,
    pub execution_mode: Option<String>,
    pub matcher: Option<String>,
    pub command: Option<String>,
    pub timeout_sec: u64,
    pub status_message: Option<String>,
    pub additional_context_limit: Option<u64>,
    pub source_path: PathBuf,
    pub plugin_id: Option<String>,
    pub enabled: bool,
    pub is_managed: bool,
    pub current_hash: String,
    pub trust_status: String,
}

fn read_result(receiver: &Receiver<std::io::Result<String>>, id: u64) -> Result<Value> {
    let deadline = Instant::now() + RESPONSE_TIMEOUT;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            bail!("Codex app-server timed out")
        }
        let line = receiver
            .recv_timeout(remaining)
            .map_err(|error| match error {
                RecvTimeoutError::Timeout => anyhow::anyhow!("Codex app-server timed out"),
                RecvTimeoutError::Disconnected => anyhow::anyhow!("Codex app-server closed"),
            })??;
        let message: Value = serde_json::from_str(&line)?;
        if message.get("id").and_then(Value::as_u64) != Some(id) {
            continue;
        }
        if message.get("error").is_some() {
            bail!("Codex app-server rejected the request")
        }
        return message
            .get("result")
            .cloned()
            .context("Codex app-server response is missing result");
    }
}
