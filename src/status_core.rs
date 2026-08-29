use crate::status::{DurableStatus, Signal, Timestamp};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AttentionExpiry {
    pub(crate) owner_id: crate::status::SignalOwnerId,
    pub(crate) generation: u64,
    pub(crate) expires_at: Timestamp,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompletionExpiry {
    pub(crate) owner_id: crate::status::SignalOwnerId,
    pub(crate) generation: u64,
    pub(crate) expires_at: Timestamp,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AggregateState {
    Attention,
    Completion,
    Execution,
    SignalOff,
}

pub struct StatusCore;

impl StatusCore {
    pub fn reduce(status: &DurableStatus) -> AggregateState {
        Self::reduce_at(status, Timestamp::now())
    }

    pub fn reduce_at(status: &DurableStatus, now: Timestamp) -> AggregateState {
        if status.owners.iter().any(|owner| {
            owner.signal == Signal::Attention
                && owner.expires_at.is_some_and(|expires_at| expires_at > now)
        }) {
            return AggregateState::Attention;
        }
        if status
            .owners
            .iter()
            .any(|owner| owner.signal == Signal::Execution)
        {
            AggregateState::Execution
        } else if status.owners.iter().any(|owner| {
            owner.signal == Signal::Completion
                && owner.expires_at.is_some_and(|expires_at| expires_at > now)
        }) {
            AggregateState::Completion
        } else {
            AggregateState::SignalOff
        }
    }

    pub fn attention_expiries(status: &DurableStatus) -> Vec<AttentionExpiry> {
        status
            .owners
            .iter()
            .filter_map(|owner| {
                if owner.signal != Signal::Attention {
                    return None;
                }
                owner.expires_at.map(|expires_at| AttentionExpiry {
                    owner_id: owner.id.clone(),
                    generation: owner.generation,
                    expires_at,
                })
            })
            .collect()
    }

    pub fn completion_expiries(status: &DurableStatus) -> Vec<CompletionExpiry> {
        status
            .owners
            .iter()
            .filter_map(|owner| {
                if owner.signal != Signal::Completion {
                    return None;
                }
                owner.expires_at.map(|expires_at| CompletionExpiry {
                    owner_id: owner.id.clone(),
                    generation: owner.generation,
                    expires_at,
                })
            })
            .collect()
    }
}
