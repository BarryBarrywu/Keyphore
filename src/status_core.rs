use crate::status::{DurableStatus, Signal};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AggregateState {
    Execution,
    SignalOff,
}

pub struct StatusCore;

impl StatusCore {
    pub fn reduce(status: &DurableStatus) -> AggregateState {
        if status
            .owners
            .iter()
            .any(|owner| owner.signal == Signal::Execution)
        {
            AggregateState::Execution
        } else {
            AggregateState::SignalOff
        }
    }
}
