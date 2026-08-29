use std::time::Duration;

use anyhow::Result;

use crate::nuphyio::{
    ReportTransport, apply_attention_signal, apply_completion_signal, apply_execution_signal,
    apply_signal_off, generate_session_challenge,
};
use crate::status::{DurableStatusStore, Timestamp};
use crate::status_core::{AggregateState, SignalExpiry, StatusCore};

const STATUS_LOCK_TIMEOUT: Duration = Duration::from_millis(100);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LightingCommand {
    OrangeAttention,
    BlueExecution,
    GreenCompletion,
    SignalOff,
}

pub trait NuPhyIoAdapter {
    fn apply(&mut self, command: LightingCommand) -> Result<()>;
}

#[derive(Default)]
pub struct Companion {
    applied: Option<AggregateState>,
}

impl Companion {
    pub fn sync(
        &mut self,
        store: &DurableStatusStore,
        adapter: &mut impl NuPhyIoAdapter,
    ) -> Result<()> {
        self.sync_at(store, adapter, Timestamp::now())
    }

    pub fn sync_at(
        &mut self,
        store: &DurableStatusStore,
        adapter: &mut impl NuPhyIoAdapter,
        now: Timestamp,
    ) -> Result<()> {
        for expiry in self.pending_expiries(store)? {
            if expiry.expires_at <= now {
                expire_signal_callback(store, &expiry, now)?;
            }
        }
        let aggregate = StatusCore::reduce_at(&store.load()?, now);
        if self.applied == Some(aggregate) {
            return Ok(());
        }
        adapter.apply(command_for(aggregate))?;
        self.applied = Some(aggregate);
        Ok(())
    }

    pub fn pending_expiries(&self, store: &DurableStatusStore) -> Result<Vec<SignalExpiry>> {
        Ok(StatusCore::expiries(&store.load()?))
    }

    pub fn handle_timeout_at(
        &mut self,
        store: &DurableStatusStore,
        adapter: &mut impl NuPhyIoAdapter,
        expiry: SignalExpiry,
        now: Timestamp,
    ) -> Result<()> {
        expire_signal_callback(store, &expiry, now)?;
        self.sync_at(store, adapter, now)
    }
}

fn expire_signal_callback(
    store: &DurableStatusStore,
    expiry: &SignalExpiry,
    now: Timestamp,
) -> Result<()> {
    store.expire_signal(
        &expiry.owner_id,
        expiry.signal,
        expiry.generation,
        expiry.expires_at,
        now,
        STATUS_LOCK_TIMEOUT,
    )
}

pub struct VerifiedNuPhyIoAdapter<'a, T> {
    transport: &'a mut T,
}

impl<'a, T> VerifiedNuPhyIoAdapter<'a, T> {
    pub fn new(transport: &'a mut T) -> Self {
        Self { transport }
    }
}

impl<T: ReportTransport> NuPhyIoAdapter for VerifiedNuPhyIoAdapter<'_, T> {
    fn apply(&mut self, command: LightingCommand) -> Result<()> {
        match command {
            LightingCommand::OrangeAttention => {
                apply_attention_signal(self.transport, generate_session_challenge())
            }
            LightingCommand::BlueExecution => {
                apply_execution_signal(self.transport, generate_session_challenge())
            }
            LightingCommand::GreenCompletion => {
                apply_completion_signal(self.transport, generate_session_challenge())
            }
            LightingCommand::SignalOff => {
                apply_signal_off(self.transport, generate_session_challenge())
            }
        }
    }
}

pub fn sync_once(store: &DurableStatusStore, adapter: &mut impl NuPhyIoAdapter) -> Result<()> {
    Companion::default().sync(store, adapter)
}

fn command_for(aggregate: AggregateState) -> LightingCommand {
    match aggregate {
        AggregateState::Attention => LightingCommand::OrangeAttention,
        AggregateState::Failure => LightingCommand::OrangeAttention,
        AggregateState::Execution => LightingCommand::BlueExecution,
        AggregateState::Completion => LightingCommand::GreenCompletion,
        AggregateState::SignalOff => LightingCommand::SignalOff,
    }
}
