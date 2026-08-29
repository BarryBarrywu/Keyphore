use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use fs2::FileExt;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
pub struct Timestamp(u64);

impl Timestamp {
    pub fn from_millis(millis: u64) -> Self {
        Self(millis)
    }

    pub fn now() -> Self {
        let millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u128::from(u64::MAX)) as u64;
        Self(millis)
    }

    pub fn saturating_add(self, duration: Duration) -> Self {
        let millis = duration.as_millis().min(u128::from(u64::MAX)) as u64;
        Self(self.0.saturating_add(millis))
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Signal {
    Attention,
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
    #[serde(default)]
    pub generation: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<Timestamp>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct DurableStatus {
    pub owners: Vec<OwnerStatus>,
    #[serde(default)]
    pub generation: u64,
}

impl DurableStatus {
    fn next_generation(&mut self) -> u64 {
        let owner_generation = self
            .owners
            .iter()
            .map(|owner| owner.generation)
            .max()
            .unwrap_or_default();
        self.generation = self.generation.max(owner_generation).saturating_add(1);
        self.generation
    }
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
        self.record_signal(
            owner.id,
            owner.turn_id,
            owner.signal,
            owner.expires_at,
            lock_timeout,
        )?;
        Ok(())
    }

    pub fn record_signal(
        &self,
        id: SignalOwnerId,
        turn_id: String,
        signal: Signal,
        expires_at: Option<Timestamp>,
        lock_timeout: Duration,
    ) -> Result<u64> {
        let mut recorded_generation = 0;
        self.update(lock_timeout, |status| {
            recorded_generation = status.next_generation();
            if let Some(existing) = status.owners.iter_mut().find(|owner| owner.id == id) {
                *existing = OwnerStatus {
                    id,
                    turn_id,
                    signal,
                    generation: recorded_generation,
                    expires_at,
                };
            } else {
                status.owners.push(OwnerStatus {
                    id,
                    turn_id,
                    signal,
                    generation: recorded_generation,
                    expires_at,
                });
            }
        })?;
        Ok(recorded_generation)
    }

    pub fn remove_owner(&self, id: &SignalOwnerId, lock_timeout: Duration) -> Result<()> {
        self.update(lock_timeout, |status| {
            status.owners.retain(|owner| &owner.id != id);
        })
    }

    pub fn remove_session(
        &self,
        product: &str,
        session_id: &str,
        lock_timeout: Duration,
    ) -> Result<()> {
        self.update(lock_timeout, |status| {
            status
                .owners
                .retain(|owner| owner.id.product != product || owner.id.session_id != session_id);
        })
    }

    pub fn replace_session_with_signal(
        &self,
        id: SignalOwnerId,
        turn_id: String,
        signal: Signal,
        lock_timeout: Duration,
    ) -> Result<()> {
        self.update(lock_timeout, |status| {
            let generation = status.next_generation();
            status.owners.retain(|owner| {
                owner.id.product != id.product || owner.id.session_id != id.session_id
            });
            status.owners.push(OwnerStatus {
                id,
                turn_id,
                signal,
                generation,
                expires_at: None,
            });
        })
    }

    pub fn expire_attention(
        &self,
        id: &SignalOwnerId,
        generation: u64,
        expires_at: Timestamp,
        now: Timestamp,
        lock_timeout: Duration,
    ) -> Result<()> {
        self.update(lock_timeout, |status| {
            status.owners.retain(|owner| {
                owner.id != *id
                    || owner.signal != Signal::Attention
                    || owner.generation != generation
                    || owner.expires_at != Some(expires_at)
                    || expires_at > now
            });
        })
    }

    fn update(
        &self,
        lock_timeout: Duration,
        update: impl FnOnce(&mut DurableStatus),
    ) -> Result<()> {
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
        update(&mut status);
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
