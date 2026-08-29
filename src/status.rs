use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use fs2::FileExt;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Signal {
    Execution,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SignalOwnerId {
    pub product: String,
    pub session_id: String,
    pub agent_id: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct OwnerStatus {
    pub id: SignalOwnerId,
    pub turn_id: String,
    pub signal: Signal,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct DurableStatus {
    pub owners: Vec<OwnerStatus>,
}

pub struct DurableStatusStore {
    path: PathBuf,
}

impl DurableStatusStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> Result<DurableStatus> {
        match fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes).context("durable status is invalid"),
            Err(error) if error.kind() == ErrorKind::NotFound => Ok(DurableStatus::default()),
            Err(error) => Err(error).context("failed to read durable status"),
        }
    }

    pub fn record_execution(&self, owner: OwnerStatus, lock_timeout: Duration) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).context("failed to create durable-status directory")?;
        }

        let lock_path = self.path.with_extension("lock");
        let lock = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&lock_path)
            .context("failed to open durable-status lock")?;
        acquire_bounded(&lock, lock_timeout)?;

        let mut status = self.load()?;
        if let Some(existing) = status
            .owners
            .iter_mut()
            .find(|existing| existing.id == owner.id)
        {
            *existing = owner;
        } else {
            status.owners.push(owner);
        }
        self.replace_atomically(&status)?;
        FileExt::unlock(&lock).context("failed to release durable-status lock")
    }

    fn replace_atomically(&self, status: &DurableStatus) -> Result<()> {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let file_name = self
            .path
            .file_name()
            .and_then(|name| name.to_str())
            .context("durable-status path needs a file name")?;
        let temporary =
            self.path
                .with_file_name(format!(".{file_name}.{}.{}.tmp", std::process::id(), nonce));
        let result = (|| -> Result<()> {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)
                .context("failed to create atomic durable-status replacement")?;
            serde_json::to_writer(&mut file, status)?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            fs::rename(&temporary, &self.path).context("failed to replace durable status")?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }
}

fn acquire_bounded(lock: &File, timeout: Duration) -> Result<()> {
    let started = Instant::now();
    loop {
        match lock.try_lock_exclusive() {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == ErrorKind::WouldBlock && started.elapsed() < timeout => {
                thread::sleep(Duration::from_millis(2));
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                bail!("timed out waiting for durable-status lock")
            }
            Err(error) => return Err(error).context("failed to lock durable status"),
        }
    }
}
