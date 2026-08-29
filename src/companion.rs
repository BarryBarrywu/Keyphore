use anyhow::Result;

use crate::nuphyio::{
    ReportTransport, apply_execution_signal, apply_signal_off, generate_session_challenge,
};
use crate::status::DurableStatusStore;
use crate::status_core::{AggregateState, StatusCore};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LightingCommand {
    BlueExecution,
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
        let aggregate = StatusCore::reduce(&store.load()?);
        if self.applied == Some(aggregate) {
            return Ok(());
        }
        adapter.apply(command_for(aggregate))?;
        self.applied = Some(aggregate);
        Ok(())
    }
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
            LightingCommand::BlueExecution => {
                apply_execution_signal(self.transport, generate_session_challenge())
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
        AggregateState::Execution => LightingCommand::BlueExecution,
        AggregateState::SignalOff => LightingCommand::SignalOff,
    }
}
