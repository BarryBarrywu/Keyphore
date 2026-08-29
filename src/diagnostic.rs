use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};

use crate::protocol::{
    Report, Request, SessionChallenge, SessionKey, ValidatedResponse, build_session_request,
    validate_response, validate_session_response,
};

const RESPONSE_TIMEOUT: Duration = Duration::from_secs(1);
const LIGHT_STATE_LEN: usize = 17;
const MAIN_LIGHT_LEN: usize = 9;
const RHYTHM_LIGHT_LEN: usize = 8;

pub const BLUE_EXECUTION_MAIN: [u8; MAIN_LIGHT_LEN] = [4, 100, 3, 0, 1, 0, 0, 0, 0xff];
pub const SIGNAL_OFF_MAIN: [u8; MAIN_LIGHT_LEN] = [3, 0, 3, 0, 1, 0, 0, 0, 0];

pub fn generate_session_challenge() -> SessionChallenge {
    let mut state = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0x9e37_79b9_7f4a_7c15);
    if state == 0 {
        state = 0x9e37_79b9_7f4a_7c15;
    }

    std::array::from_fn(|_| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state as u8
    })
}

pub trait ReportTransport {
    fn send(&mut self, report: &Report) -> Result<()>;
    fn receive(&mut self, timeout: Duration) -> Result<Option<Report>>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExerciseEvidence {
    pub blue_main: [u8; MAIN_LIGHT_LEN],
    pub signal_off_main: [u8; MAIN_LIGHT_LEN],
    pub rhythm_before: [u8; RHYTHM_LIGHT_LEN],
    pub rhythm_after_blue: [u8; RHYTHM_LIGHT_LEN],
    pub rhythm_after_off: [u8; RHYTHM_LIGHT_LEN],
}

pub fn exercise_main_backlight<T, F>(
    transport: &mut T,
    challenge: SessionChallenge,
    observe_blue: F,
) -> Result<ExerciseEvidence>
where
    T: ReportTransport,
    F: FnOnce(),
{
    let key = start_temporary_session(transport, challenge)?;
    let initial = read_light_state(transport, key)?;

    let blue = match apply_and_verify_state(
        transport,
        key,
        &initial,
        &BLUE_EXECUTION_MAIN,
        "blue execution signal",
    ) {
        Ok(state) => state,
        Err(error) => {
            let cleanup = apply_and_verify_state(
                transport,
                key,
                &initial,
                &SIGNAL_OFF_MAIN,
                "signal-off cleanup",
            );
            return match cleanup {
                Ok(_) => Err(error.context("signal-off cleanup verified after diagnostic failure")),
                Err(cleanup_error) => Err(anyhow::anyhow!(
                    "{error:#}; signal-off cleanup also failed: {cleanup_error:#}"
                )),
            };
        }
    };
    observe_blue();

    let off = apply_and_verify_state(
        transport,
        key,
        &initial,
        &SIGNAL_OFF_MAIN,
        "signal-off state",
    )?;

    Ok(ExerciseEvidence {
        blue_main: blue[..MAIN_LIGHT_LEN].try_into().unwrap(),
        signal_off_main: off[..MAIN_LIGHT_LEN].try_into().unwrap(),
        rhythm_before: initial[MAIN_LIGHT_LEN..].try_into().unwrap(),
        rhythm_after_blue: blue[MAIN_LIGHT_LEN..].try_into().unwrap(),
        rhythm_after_off: off[MAIN_LIGHT_LEN..].try_into().unwrap(),
    })
}

fn apply_and_verify_state<T: ReportTransport>(
    transport: &mut T,
    key: SessionKey,
    initial: &[u8; LIGHT_STATE_LEN],
    expected: &[u8; MAIN_LIGHT_LEN],
    operation: &str,
) -> Result<[u8; LIGHT_STATE_LEN]> {
    write_main_state(transport, key, expected)?;
    let state = read_light_state(transport, key)?;
    verify_main_state(&state, expected, operation)?;
    verify_rhythm_unchanged(initial, &state, operation)?;
    Ok(state)
}

fn start_temporary_session<T: ReportTransport>(
    transport: &mut T,
    challenge: SessionChallenge,
) -> Result<SessionKey> {
    transport
        .send(&build_session_request(challenge))
        .context("failed to send temporary-session request")?;
    let started = Instant::now();
    loop {
        let remaining = remaining(started)?;
        let Some(response) = transport.receive(remaining)? else {
            bail!("timed out waiting for temporary-session response");
        };
        if response[0] == 0xaa
            && response[1] == 0xee
            && let Ok(key) = validate_session_response(&response, &challenge)
        {
            return Ok(key);
        }
    }
}

fn read_light_state<T: ReportTransport>(
    transport: &mut T,
    key: SessionKey,
) -> Result<[u8; LIGHT_STATE_LEN]> {
    let request = Request::read(0, LIGHT_STATE_LEN as u8)?;
    let response = exchange_request(transport, &request, key)?;
    response
        .payload
        .try_into()
        .map_err(|_| anyhow::anyhow!("light-state response did not contain 17 bytes"))
}

fn write_main_state<T: ReportTransport>(
    transport: &mut T,
    key: SessionKey,
    state: &[u8; MAIN_LIGHT_LEN],
) -> Result<()> {
    let state_request = Request::write(0, state)?;
    exchange_request(transport, &state_request, key)?;

    let brightness_request = Request::write(1, &state[1..2])?;
    exchange_request(transport, &brightness_request, key)?;
    Ok(())
}

fn exchange_request<T: ReportTransport>(
    transport: &mut T,
    request: &Request,
    key: SessionKey,
) -> Result<ValidatedResponse> {
    transport.send(&request.encode(key))?;
    let started = Instant::now();
    loop {
        let remaining = remaining(started)?;
        let Some(response) = transport.receive(remaining)? else {
            bail!("timed out waiting for correlated HID response");
        };
        if request.is_response_candidate(&response, key) {
            return validate_response(&response, request, key);
        }
    }
}

fn remaining(started: Instant) -> Result<Duration> {
    RESPONSE_TIMEOUT
        .checked_sub(started.elapsed())
        .filter(|remaining| !remaining.is_zero())
        .ok_or_else(|| anyhow::anyhow!("timed out waiting for correlated HID response"))
}

fn verify_main_state(
    state: &[u8; LIGHT_STATE_LEN],
    expected: &[u8; MAIN_LIGHT_LEN],
    operation: &str,
) -> Result<()> {
    if &state[..MAIN_LIGHT_LEN] != expected {
        bail!(
            "{operation} did not read back from the main backlight: expected {:02x?}, got {:02x?}",
            expected,
            &state[..MAIN_LIGHT_LEN]
        );
    }
    Ok(())
}

fn verify_rhythm_unchanged(
    before: &[u8; LIGHT_STATE_LEN],
    after: &[u8; LIGHT_STATE_LEN],
    operation: &str,
) -> Result<()> {
    if before[MAIN_LIGHT_LEN..] != after[MAIN_LIGHT_LEN..] {
        bail!("rhythm light bar changed while applying {operation}");
    }
    Ok(())
}
