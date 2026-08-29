use std::collections::VecDeque;
use std::time::Duration;

use anyhow::{Result, bail};
use nuphy_codex::nuphyio::{
    ORANGE_ATTENTION_MAIN, ReportTransport, apply_attention_signal, exercise_main_backlight,
};
use nuphy_codex::protocol::{REPORT_LEN, Report, SessionChallenge, checksum};

const KEY: u8 = 0xa5;
const INITIAL_MAIN: [u8; 9] = [3, 40, 2, 0, 1, 0, 0xaa, 0xbb, 0xcc];
const INITIAL_RHYTHM: [u8; 8] = [4, 70, 2, 1, 0, 0x11, 0x22, 0x33];
const BLUE_MAIN: [u8; 9] = [4, 100, 3, 0, 1, 0, 0, 0, 0xff];
const SIGNAL_OFF: [u8; 9] = [3, 0, 3, 0, 1, 0, 0, 0, 0];

struct FakeKeyboard {
    challenge: SessionChallenge,
    state: [u8; 17],
    writes: Vec<Report>,
    responses: VecDeque<Report>,
    corrupt_blue_readback: bool,
    inject_unrelated_reports: bool,
    reads: usize,
}

impl FakeKeyboard {
    fn new(challenge: SessionChallenge) -> Self {
        let mut state = [0u8; 17];
        state[..9].copy_from_slice(&INITIAL_MAIN);
        state[9..].copy_from_slice(&INITIAL_RHYTHM);
        Self {
            challenge,
            state,
            writes: Vec::new(),
            responses: VecDeque::new(),
            corrupt_blue_readback: false,
            inject_unrelated_reports: false,
            reads: 0,
        }
    }

    fn response(&self, command: u8, length: u8, address: u16, payload: &[u8]) -> Report {
        let mut response = [0u8; REPORT_LEN];
        response[0] = 0xaa;
        response[1] = command;
        response[4] = length ^ KEY;
        response[5] = address as u8 ^ KEY;
        response[6] = (address >> 8) as u8 ^ KEY;
        response[7] = KEY;
        for (encoded, byte) in response[8..].iter_mut().zip(payload) {
            *encoded = *byte ^ KEY;
        }
        response[3] = checksum(&response);
        response
    }
}

impl ReportTransport for FakeKeyboard {
    fn send(&mut self, report: &Report) -> Result<()> {
        self.writes.push(*report);
        match report[1] {
            0xee => {
                let mut response = [0u8; REPORT_LEN];
                response[..8].copy_from_slice(&[0xaa, 0xee, 0, 0, KEY, KEY, KEY, KEY]);
                for (encoded, sent) in response[8..].iter_mut().zip(self.challenge) {
                    *encoded = sent ^ KEY;
                }
                response[3] = checksum(&response);
                if self.inject_unrelated_reports {
                    let mut unrelated = response;
                    unrelated[20] ^= 1;
                    unrelated[3] = checksum(&unrelated);
                    self.responses.push_back(unrelated);
                }
                self.responses.push_back(response);
            }
            0xd5 => {
                self.reads += 1;
                let length = report[4] ^ KEY;
                let address = u16::from(report[5] ^ KEY) | (u16::from(report[6] ^ KEY) << 8);
                let end = usize::from(address) + usize::from(length);
                let mut payload = self.state[usize::from(address)..end].to_vec();
                if self.corrupt_blue_readback && self.reads == 2 {
                    payload[0] ^= 1;
                }
                let response = self.response(0xd5, length, address, &payload);
                self.queue_response_with_optional_noise(response);
            }
            0xd6 => {
                let length = report[4] ^ KEY;
                let address = u16::from(report[5] ^ KEY) | (u16::from(report[6] ^ KEY) << 8);
                let start = usize::from(address);
                let end = start + usize::from(length);
                if end > 9 {
                    bail!("diagnostic attempted to write outside main backlight");
                }
                for (target, encoded) in self.state[start..end]
                    .iter_mut()
                    .zip(&report[8..8 + usize::from(length)])
                {
                    *target = *encoded ^ KEY;
                }
                let response = self.response(0xd6, length, address, &[]);
                self.queue_response_with_optional_noise(response);
            }
            command => bail!("unexpected command 0x{command:02x}"),
        }
        Ok(())
    }

    fn receive(&mut self, _timeout: Duration) -> Result<Option<Report>> {
        Ok(self.responses.pop_front())
    }
}

impl FakeKeyboard {
    fn queue_response_with_optional_noise(&mut self, response: Report) {
        if self.inject_unrelated_reports {
            let mut unrelated = response;
            unrelated[7] ^= 1;
            unrelated[3] = checksum(&unrelated);
            self.responses.push_back(unrelated);
        }
        self.responses.push_back(response);
    }
}

#[test]
fn failed_blue_verification_still_turns_the_main_backlight_off() {
    let challenge = std::array::from_fn(|index| index as u8);
    let mut keyboard = FakeKeyboard::new(challenge);
    keyboard.corrupt_blue_readback = true;

    assert!(exercise_main_backlight(&mut keyboard, challenge, || {}).is_err());
    assert_eq!(keyboard.state[..9], SIGNAL_OFF);
    assert_eq!(keyboard.state[9..], INITIAL_RHYTHM);
}

#[test]
fn unrelated_reports_are_skipped_until_the_correlated_response_arrives() {
    let challenge = std::array::from_fn(|index| index as u8);
    let mut keyboard = FakeKeyboard::new(challenge);
    keyboard.inject_unrelated_reports = true;

    let evidence = exercise_main_backlight(&mut keyboard, challenge, || {}).unwrap();

    assert_eq!(evidence.blue_main, BLUE_MAIN);
    assert_eq!(evidence.signal_off_main, SIGNAL_OFF);
}

#[test]
fn exercise_applies_blue_then_off_without_changing_the_rhythm_light_bar() {
    let challenge = std::array::from_fn(|index| index as u8);
    let mut keyboard = FakeKeyboard::new(challenge);
    let mut observed_blue = false;

    let evidence = exercise_main_backlight(&mut keyboard, challenge, || {
        observed_blue = true;
    })
    .unwrap();

    assert!(observed_blue);
    assert_eq!(evidence.blue_main, BLUE_MAIN);
    assert_eq!(evidence.signal_off_main, SIGNAL_OFF);
    assert_eq!(evidence.rhythm_before, INITIAL_RHYTHM);
    assert_eq!(evidence.rhythm_after_blue, INITIAL_RHYTHM);
    assert_eq!(evidence.rhythm_after_off, INITIAL_RHYTHM);
    assert_eq!(keyboard.state[..9], SIGNAL_OFF);
    assert_eq!(keyboard.state[9..], INITIAL_RHYTHM);

    let lighting_writes: Vec<_> = keyboard
        .writes
        .iter()
        .filter(|report| report[1] == 0xd6)
        .collect();
    assert_eq!(lighting_writes.len(), 4);
    assert!(lighting_writes.iter().all(|report| {
        let length = report[4] ^ KEY;
        let address = u16::from(report[5] ^ KEY) | (u16::from(report[6] ^ KEY) << 8);
        usize::from(address) + usize::from(length) <= 9
    }));
}

#[test]
fn attention_applies_orange_breath_to_main_backlight_only() {
    let challenge = std::array::from_fn(|index| index as u8);
    let mut keyboard = FakeKeyboard::new(challenge);

    apply_attention_signal(&mut keyboard, challenge).unwrap();

    assert_eq!(keyboard.state[..9], ORANGE_ATTENTION_MAIN);
    assert_eq!(keyboard.state[9..], INITIAL_RHYTHM);
}
