use anyhow::{Result, bail};

pub const REPORT_LEN: usize = 64;
const PAYLOAD_LEN: usize = REPORT_LEN - 8;
const HOST_DIRECTION: u8 = 0x55;
const DEVICE_DIRECTION: u8 = 0xaa;

pub type Report = [u8; REPORT_LEN];
pub type SessionChallenge = [u8; PAYLOAD_LEN];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Command {
    GetData,
    SetData,
    TemporarySession,
}

impl Command {
    const fn code(self) -> u8 {
        match self {
            Self::GetData => 0xd5,
            Self::SetData => 0xd6,
            Self::TemporarySession => 0xee,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SessionKey(u8);

impl SessionKey {
    pub const fn new(value: u8) -> Self {
        Self(value)
    }

    pub const fn value(self) -> u8 {
        self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Request {
    command: Command,
    address: u16,
    response_len: u8,
    payload: Vec<u8>,
}

impl Request {
    pub fn write(address: u16, payload: &[u8]) -> Result<Self> {
        let response_len = u8::try_from(payload.len())?;
        if payload.len() > PAYLOAD_LEN {
            bail!("protocol payload exceeds {PAYLOAD_LEN} bytes");
        }
        Ok(Self {
            command: Command::SetData,
            address,
            response_len,
            payload: payload.to_vec(),
        })
    }

    pub fn read(address: u16, response_len: u8) -> Result<Self> {
        if usize::from(response_len) > PAYLOAD_LEN {
            bail!("protocol response exceeds {PAYLOAD_LEN} bytes");
        }
        Ok(Self {
            command: Command::GetData,
            address,
            response_len,
            payload: Vec::new(),
        })
    }

    pub fn encode(&self, key: SessionKey) -> Report {
        let mut report = [0u8; REPORT_LEN];
        report[0] = HOST_DIRECTION;
        report[1] = self.command.code();
        report[4] = self.response_len ^ key.value();
        report[5] = self.address as u8 ^ key.value();
        report[6] = (self.address >> 8) as u8 ^ key.value();
        report[7] = key.value();
        for (encoded, byte) in report[8..].iter_mut().zip(&self.payload) {
            *encoded = *byte ^ key.value();
        }
        report[3] = checksum(&report);
        report
    }

    pub fn is_response_candidate(&self, response: &Report, key: SessionKey) -> bool {
        if validate_envelope(response, self.command).is_err() {
            return false;
        }
        let identity = decode_identity(response, key);
        identity.length == self.response_len
            && identity.address == self.address
            && identity.handle == 0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ValidatedResponse {
    pub payload: Vec<u8>,
}

pub fn build_session_request(challenge: SessionChallenge) -> Report {
    let mut report = [0u8; REPORT_LEN];
    report[0] = HOST_DIRECTION;
    report[1] = Command::TemporarySession.code();
    report[8..].copy_from_slice(&challenge);
    report[3] = checksum(&report);
    report
}

pub fn validate_session_response(
    response: &Report,
    challenge: &SessionChallenge,
) -> Result<SessionKey> {
    validate_envelope(response, Command::TemporarySession)?;

    let key = SessionKey::new(response[4]);
    if response[4..8].iter().any(|byte| *byte != key.value()) {
        bail!("temporary-session response contains mismatched key bytes");
    }
    for (index, (received, sent)) in response[8..].iter().zip(challenge).enumerate() {
        if *received != (*sent ^ key.value()) {
            bail!("temporary-session response does not match challenge at byte {index}");
        }
    }
    Ok(key)
}

pub fn validate_response(
    response: &Report,
    request: &Request,
    key: SessionKey,
) -> Result<ValidatedResponse> {
    validate_envelope(response, request.command)?;

    let identity = decode_identity(response, key);
    if identity.length != request.response_len {
        bail!(
            "response length mismatch: expected {}, got {}",
            request.response_len,
            identity.length
        );
    }
    if identity.address != request.address {
        bail!(
            "response address mismatch: expected {}, got {}",
            request.address,
            identity.address
        );
    }
    if identity.handle != 0 {
        bail!(
            "response handle mismatch: expected 0, got {}",
            identity.handle
        );
    }

    let payload = response[8..8 + usize::from(identity.length)]
        .iter()
        .map(|byte| *byte ^ key.value())
        .collect();
    Ok(ValidatedResponse { payload })
}

#[derive(Clone, Copy)]
struct ResponseIdentity {
    length: u8,
    address: u16,
    handle: u8,
}

fn decode_identity(response: &Report, key: SessionKey) -> ResponseIdentity {
    ResponseIdentity {
        length: response[4] ^ key.value(),
        address: u16::from(response[5] ^ key.value()) | (u16::from(response[6] ^ key.value()) << 8),
        handle: response[7] ^ key.value(),
    }
}

pub fn parse_report(bytes: &[u8]) -> Result<Report> {
    bytes
        .try_into()
        .map_err(|_| anyhow::anyhow!("HID report must be exactly {REPORT_LEN} bytes"))
}

pub fn checksum(report: &Report) -> u8 {
    report[4..]
        .iter()
        .fold(0u8, |sum, byte| sum.wrapping_add(*byte))
}

fn validate_envelope(response: &Report, command: Command) -> Result<()> {
    if response[0] != DEVICE_DIRECTION {
        bail!("response direction must be 0xaa");
    }
    if response[1] != command.code() {
        bail!(
            "response command mismatch: expected 0x{:02x}, got 0x{:02x}",
            command.code(),
            response[1]
        );
    }
    let expected = checksum(response);
    if response[3] != expected {
        bail!(
            "response checksum mismatch: expected 0x{expected:02x}, got 0x{:02x}",
            response[3]
        );
    }
    Ok(())
}
