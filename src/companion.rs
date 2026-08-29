use std::time::Duration;

use anyhow::Result;

use crate::nuphyio::{
    BLUE_EXECUTION_MAIN, GREEN_COMPLETION_MAIN, ORANGE_ATTENTION_MAIN, ReportTransport,
    SIGNAL_OFF_MAIN, apply_main_signal, generate_session_challenge, main_signal_matches,
};
use crate::status::{DurableStatusStore, Timestamp};
use crate::status_core::{AggregateState, SignalExpiry, StatusCore};

const STATUS_LOCK_TIMEOUT: Duration = Duration::from_millis(100);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LightingCommand {
    OrangeAttention,
    Failure,
    BlueExecution,
    GreenCompletion,
    SignalOff,
}

impl LightingCommand {
    fn main_signal(self) -> (&'static [u8; 9], &'static str) {
        match self {
            Self::OrangeAttention => (&ORANGE_ATTENTION_MAIN, "orange attention signal"),
            Self::Failure => (&ORANGE_ATTENTION_MAIN, "failure signal"),
            Self::BlueExecution => (&BLUE_EXECUTION_MAIN, "blue execution signal"),
            Self::GreenCompletion => (&GREEN_COMPLETION_MAIN, "green completion signal"),
            Self::SignalOff => (&SIGNAL_OFF_MAIN, "signal-off state"),
        }
    }
}

pub trait NuPhyIoAdapter {
    fn apply(&mut self, command: LightingCommand) -> Result<()>;
}

pub trait HealthAwareNuPhyIoAdapter: NuPhyIoAdapter {
    fn displays(&mut self, command: LightingCommand) -> Result<bool>;
}

#[derive(Default)]
pub struct Companion {
    applied: Option<AggregateState>,
}

impl Companion {
    pub fn device_reconnected(
        &mut self,
        store: &DurableStatusStore,
        adapter: &mut impl NuPhyIoAdapter,
    ) -> Result<()> {
        self.applied = None;
        self.sync(store, adapter)
    }

    pub fn health_check(
        &mut self,
        store: &DurableStatusStore,
        adapter: &mut impl HealthAwareNuPhyIoAdapter,
    ) -> Result<()> {
        let aggregate = StatusCore::reduce_at(&store.load()?, Timestamp::now());
        let command = command_for(aggregate);
        if adapter.displays(command)? {
            self.applied = Some(aggregate);
            return Ok(());
        }
        adapter.apply(command)?;
        self.applied = Some(aggregate);
        Ok(())
    }

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
        let (expected, operation) = command.main_signal();
        apply_main_signal(
            self.transport,
            generate_session_challenge(),
            expected,
            operation,
        )
    }
}

impl<T: ReportTransport> HealthAwareNuPhyIoAdapter for VerifiedNuPhyIoAdapter<'_, T> {
    fn displays(&mut self, command: LightingCommand) -> Result<bool> {
        let (expected, _) = command.main_signal();
        main_signal_matches(self.transport, generate_session_challenge(), expected)
    }
}

pub fn sync_once(store: &DurableStatusStore, adapter: &mut impl NuPhyIoAdapter) -> Result<()> {
    Companion::default().sync(store, adapter)
}

fn command_for(aggregate: AggregateState) -> LightingCommand {
    match aggregate {
        AggregateState::Attention => LightingCommand::OrangeAttention,
        AggregateState::Failure => LightingCommand::Failure,
        AggregateState::Execution => LightingCommand::BlueExecution,
        AggregateState::Completion => LightingCommand::GreenCompletion,
        AggregateState::SignalOff => LightingCommand::SignalOff,
    }
}
