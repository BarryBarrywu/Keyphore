use std::{collections::VecDeque, fs, time::Duration};

use keyphore::{
    companion::{Companion, VerifiedNuPhyIoAdapter},
    hook::{append_hook_audit, handle_codex_event_at},
    nuphyio::ReportTransport,
    power::{PowerEvent, PowerGate},
    protocol::{Report, checksum},
    status::{DurableStatusStore, Timestamp},
    status_core::{AggregateState, StatusCore},
};
use serde_json::{Value, json};

// A byte-level keyboard boundary: responses derive from requests, never from expected results.
struct Keyboard {
    state: Vec<u8>,
    responses: VecDeque<Report>,
    writes: Vec<Vec<u8>>,
}

impl ReportTransport for Keyboard {
    fn send(&mut self, request: &Report) -> anyhow::Result<()> {
        if request[1] == 0xd6 {
            self.writes.push(request.to_vec());
        }
        let key = 0xa5;
        let mut response = [0u8; 64];
        response[0] = 0xaa;
        response[1] = request[1];
        if request[1] == 0xee {
            response[4..8].fill(key);
            for i in 8..64 {
                response[i] = request[i] ^ key;
            }
        } else {
            response[4..8].copy_from_slice(&request[4..8]);
            let length = usize::from(request[4] ^ key);
            let address = usize::from(request[5] ^ key) | (usize::from(request[6] ^ key) << 8);
            match request[1] {
                0xd5 => {
                    for i in 0..length {
                        response[8 + i] = self.state[address + i] ^ key;
                    }
                }
                0xd6 => {
                    anyhow::ensure!(address + length <= 9, "write outside main backlight");
                    for i in 0..length {
                        self.state[address + i] = request[8 + i] ^ key;
                    }
                }
                _ => anyhow::bail!("unexpected protocol command"),
            }
        }
        response[3] = checksum(&response);
        self.responses.push_back(response);
        Ok(())
    }

    fn receive(&mut self, _: Duration) -> anyhow::Result<Option<Report>> {
        Ok(self.responses.pop_front())
    }
}

#[test]
fn canonical_swift_parity_scenarios() {
    let fixture: Value = serde_json::from_str(include_str!("fixtures/swift-parity.json")).unwrap();
    let mut observations = Vec::new();
    for scenario in fixture["scenarios"].as_array().unwrap() {
        let directory = tempfile::tempdir().unwrap();
        let store = DurableStatusStore::new(directory.path().join("status.json"));
        let audit = directory.path().join("audit.jsonl");
        let mut companion = Companion::default();
        let mut expiry = None;
        let epoch = serde_json::to_value(Timestamp::now())
            .unwrap()
            .as_u64()
            .unwrap();
        let power = PowerGate::default();
        let mut keyboard = Keyboard {
            state: [
                vec![3, 40, 2, 0, 1, 0, 170, 187, 204],
                serde_json::from_value(fixture["rhythm"].clone()).unwrap(),
            ]
            .concat(),
            responses: VecDeque::new(),
            writes: Vec::new(),
        };
        for (index, step) in scenario["steps"].as_array().unwrap().iter().enumerate() {
            let now = Timestamp::from_millis(epoch + step["at"].as_u64().unwrap());
            let write_start = keyboard.writes.len();
            if let Some(event) = step.get("event") {
                let input = event.to_string();
                handle_codex_event_at(&input, &store, Duration::from_millis(100), now).unwrap();
                append_hook_audit(&input, &audit, Duration::from_millis(100), now).unwrap();
            }
            if step["capture_expiry"] == true {
                expiry = companion
                    .pending_expiries(&store)
                    .unwrap()
                    .into_iter()
                    .next();
                assert!(expiry.is_some());
            }
            if step["restart"] == true {
                companion = Companion::default();
                keyboard.state[..9].fill(0);
            }
            match step["power"].as_str() {
                Some("sleep") => power.handle(PowerEvent::WillSleep),
                Some("wake") => {
                    power.handle(PowerEvent::DidWake);
                    companion = Companion::default();
                }
                _ => (),
            }
            if step["reconnect"] == true {
                keyboard.state[..9].fill(0);
            }
            let mut adapter = VerifiedNuPhyIoAdapter::new(&mut keyboard);
            if step["reconnect"] == true {
                companion.device_reconnected(&store, &mut adapter).unwrap();
            } else if power.begin_hid_access().is_none() {
            } else if step["fire_expiry"] == true {
                companion
                    .handle_timeout_at(&store, &mut adapter, expiry.clone().unwrap(), now)
                    .unwrap();
            } else {
                companion.sync_at(&store, &mut adapter, now).unwrap();
            }
            let status = store.load().unwrap();
            let displayed_signal = fixture["main_states"]
                .as_object()
                .unwrap()
                .iter()
                .find(|(_, main)| **main == json!(keyboard.state[..9]))
                .unwrap()
                .0;
            assert_eq!(
                displayed_signal.as_str(),
                step["displayed_signal"],
                "{} step {index}",
                scenario["id"]
            );
            assert_eq!(
                json!(keyboard.state[..9]),
                fixture["main_states"][displayed_signal]
            );
            assert_eq!(json!(keyboard.state[9..]), fixture["rhythm"]);
            let aggregate = match StatusCore::reduce_at(&status, now) {
                AggregateState::Attention => "attention",
                AggregateState::Execution => "execution",
                AggregateState::Completion => "completion",
                AggregateState::SignalOff => "off",
                AggregateState::Failure => panic!("unexpected failure signal"),
            };
            assert_eq!(aggregate, step["aggregate"]);
            let persisted = fs::read_to_string(store.path()).unwrap();
            let audited = fs::read_to_string(&audit).unwrap();
            for marker in fixture["private_markers"].as_array().unwrap() {
                assert!(!persisted.contains(marker.as_str().unwrap()));
                assert!(!audited.contains(marker.as_str().unwrap()));
            }
            let mut owners = status
                .owners
                .iter()
                .map(|owner| {
                    json!({
                        "session": owner.id.session_id, "agent": owner.id.agent_id,
                        "product": owner.id.product, "turn": owner.turn_id, "signal": owner.signal,
                        "generation": owner.generation, "expires_at": serde_json::to_value(owner.expires_at).unwrap().as_u64().unwrap() - epoch,
                    })
                })
                .collect::<Vec<_>>();
            owners.sort_by_key(Value::to_string);
            observations.push(json!({"scenario": scenario["id"], "step": index,
                "aggregate": aggregate, "displayed_signal": displayed_signal, "owners": owners,
                "main": keyboard.state[..9], "rhythm": keyboard.state[9..], "privacy": "passed", "lighting_packets": keyboard.writes[write_start..]}));
        }
    }
    if let Ok(directory) = std::env::var("KEYPHORE_PARITY_OUTPUT") {
        fs::write(
            std::path::Path::new(&directory).join("rust-parity.json"),
            serde_json::to_vec_pretty(&observations).unwrap(),
        )
        .unwrap();
    }
}
