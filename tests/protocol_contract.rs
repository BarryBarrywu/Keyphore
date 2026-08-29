use nuphy_codex::nuphyio::ORANGE_ATTENTION_MAIN;
use nuphy_codex::protocol::{
    REPORT_LEN, Request, SessionKey, build_session_request, validate_response,
    validate_session_response,
};

#[test]
fn main_backlight_write_matches_the_fixed_width_nuphyio_fixture() {
    let request =
        Request::write(0, &[0x04, 0x64, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0xff]).unwrap();

    let report = request.encode(SessionKey::new(0x5a));

    assert_eq!(report.len(), REPORT_LEN);
    assert_eq!(
        &report[..17],
        &[
            0x55, 0xd6, 0x00, 0xbe, 0x53, 0x5a, 0x5a, 0x5a, 0x5e, 0x3e, 0x59, 0x5a, 0x5b, 0x5a,
            0x5a, 0x5a, 0xa5,
        ]
    );
    assert!(report[17..].iter().all(|byte| *byte == 0));
}

#[test]
fn orange_attention_uses_the_verified_breath_effect_packet() {
    let report = Request::write(0, &ORANGE_ATTENTION_MAIN)
        .unwrap()
        .encode(SessionKey::new(0x5a));

    assert_eq!(report.len(), REPORT_LEN);
    assert_eq!(
        &report[..17],
        &[
            0x55, 0xd6, 0x00, 0x3e, 0x53, 0x5a, 0x5a, 0x5a, 0x5e, 0x3e, 0x59, 0x5a, 0x5b, 0x5a,
            0xa5, 0xda, 0x5a,
        ]
    );
    assert!(report[17..].iter().all(|byte| *byte == 0));
}

#[test]
fn temporary_session_response_must_correlate_with_the_challenge() {
    let challenge = std::array::from_fn(|index| index as u8);
    let request = build_session_request(challenge);
    assert_eq!(&request[..8], &[0x55, 0xee, 0x00, 0x04, 0, 0, 0, 0]);

    let mut response = [0u8; REPORT_LEN];
    response[..8].copy_from_slice(&[0xaa, 0xee, 0x00, 0x98, 0xa5, 0xa5, 0xa5, 0xa5]);
    for (received, sent) in response[8..].iter_mut().zip(challenge) {
        *received = sent ^ 0xa5;
    }

    assert_eq!(
        validate_session_response(&response, &challenge).unwrap(),
        SessionKey::new(0xa5)
    );

    response[20] ^= 1;
    response[3] = response[4..]
        .iter()
        .fold(0u8, |sum, byte| sum.wrapping_add(*byte));
    assert!(validate_session_response(&response, &challenge).is_err());
}

#[test]
fn response_requires_matching_direction_command_address_length_and_checksum() {
    let request = Request::write(0, &[0; 9]).unwrap();
    let key = SessionKey::new(0x5a);
    let mut response = [0u8; REPORT_LEN];
    response[..8].copy_from_slice(&[0xaa, 0xd6, 0x00, 0x61, 0x53, 0x5a, 0x5a, 0x5a]);

    assert!(validate_response(&response, &request, key).is_ok());

    for index in [0, 1, 4, 5, 3] {
        let mut malformed = response;
        malformed[index] ^= 1;
        assert!(
            validate_response(&malformed, &request, key).is_err(),
            "field at index {index} was not rejected"
        );
    }

    let mut wrong_handle = response;
    wrong_handle[7] ^= 1;
    wrong_handle[3] = nuphy_codex::protocol::checksum(&wrong_handle);
    assert!(validate_response(&wrong_handle, &request, key).is_err());
}

#[test]
fn malformed_or_oversized_reports_are_rejected() {
    assert!(Request::write(0, &[0; 57]).is_err());

    let key = SessionKey::new(0x5a);
    let request = Request::read(0, 17).unwrap();
    let mut response = [0u8; REPORT_LEN];
    response[..8].copy_from_slice(&[0xaa, 0xd5, 0x00, 0x59, 0x4b, 0x5a, 0x5a, 0x5a]);
    assert!(validate_response(&response, &request, key).is_ok());

    let truncated = &response[..63];
    assert!(nuphy_codex::protocol::parse_report(truncated).is_err());
}
