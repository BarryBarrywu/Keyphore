import KeyphoreCore
import XCTest

final class NuPhyIOProtocolTests: XCTestCase {
    func testSignalPacketsMatchAcceptedFixedWidthFixtures() throws {
        let key = NuPhySessionKey(0x5a)
        let fixtures: [([UInt8], [UInt8])] = [
            (
                [3, 100, 3, 0, 1, 0, 0, 0, 255],
                [0x55, 0xd6, 0, 0xb9, 0x53, 0x5a, 0x5a, 0x5a, 0x59, 0x3e, 0x59, 0x5a, 0x5b, 0x5a, 0x5a, 0x5a, 0xa5]
            ),
            (
                [3, 100, 3, 0, 1, 0, 255, 132, 0],
                [0x55, 0xd6, 0, 0x3d, 0x53, 0x5a, 0x5a, 0x5a, 0x59, 0x3e, 0x59, 0x5a, 0x5b, 0x5a, 0xa5, 0xde, 0x5a]
            ),
            (
                [3, 100, 3, 0, 1, 0, 0, 255, 0],
                [0x55, 0xd6, 0, 0xb9, 0x53, 0x5a, 0x5a, 0x5a, 0x59, 0x3e, 0x59, 0x5a, 0x5b, 0x5a, 0x5a, 0xa5, 0x5a]
            ),
            (
                [3, 0, 3, 0, 1, 0, 0, 0, 0],
                [0x55, 0xd6, 0, 0x8a, 0x53, 0x5a, 0x5a, 0x5a, 0x59, 0x5a, 0x59, 0x5a, 0x5b, 0x5a, 0x5a, 0x5a, 0x5a]
            ),
        ]

        for (mainState, expectedPrefix) in fixtures {
            let report = try NuPhyRequest.write(address: 0, payload: mainState).encoded(using: key)
            XCTAssertEqual(Array(report.prefix(17)), expectedPrefix)
            XCTAssertTrue(report.dropFirst(17).allSatisfy { $0 == 0 })
        }
    }

    func testTemporarySessionResponseMustCorrelateWithChallenge() throws {
        let challenge = (0..<56).map(UInt8.init)
        let request = try NuPhyProtocol.temporarySessionRequest(challenge: challenge)
        XCTAssertEqual(Array(request.prefix(8)), [0x55, 0xee, 0, 0x04, 0, 0, 0, 0])

        var response = Array(repeating: UInt8(0), count: 64)
        response[0] = 0xaa
        response[1] = 0xee
        response[4...7] = ArraySlice(repeating: 0xa5, count: 4)
        for index in challenge.indices {
            response[index + 8] = challenge[index] ^ 0xa5
        }
        response[3] = NuPhyProtocol.checksum(response)

        XCTAssertEqual(
            try NuPhyProtocol.validateTemporarySession(response, challenge: challenge),
            NuPhySessionKey(0xa5)
        )

        response[20] ^= 1
        response[3] = NuPhyProtocol.checksum(response)
        XCTAssertThrowsError(
            try NuPhyProtocol.validateTemporarySession(response, challenge: challenge)
        )
    }

    func testResponseRequiresCorrelatedEnvelopeAndIdentity() throws {
        let request = try NuPhyRequest.write(address: 0, payload: Array(repeating: 0, count: 9))
        let key = NuPhySessionKey(0x5a)
        var response = Array(repeating: UInt8(0), count: 64)
        response[0] = 0xaa
        response[1] = 0xd6
        response[4] = 0x53
        response[5] = 0x5a
        response[6] = 0x5a
        response[7] = 0x5a
        response[3] = NuPhyProtocol.checksum(response)

        XCTAssertEqual(
            try NuPhyProtocol.validate(response, for: request, key: key),
            Array(repeating: 0x5a, count: 9)
        )

        for index in [0, 1, 4, 5, 7, 3] {
            var malformed = response
            malformed[index] ^= 1
            if index != 3 {
                malformed[3] = NuPhyProtocol.checksum(malformed)
            }
            XCTAssertThrowsError(try NuPhyProtocol.validate(malformed, for: request, key: key))
        }
    }

    func testRejectsWrongReportAndPayloadLengths() {
        XCTAssertThrowsError(
            try NuPhyRequest.write(address: 0, payload: Array(repeating: 0, count: 57))
        )
        XCTAssertThrowsError(try NuPhyProtocol.parseReport(Array(repeating: 0, count: 63)))
    }
}
