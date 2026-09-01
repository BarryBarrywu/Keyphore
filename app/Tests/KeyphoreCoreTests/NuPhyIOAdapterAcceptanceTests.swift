import KeyphoreCore
import XCTest

final class NuPhyIOAdapterAcceptanceTests: XCTestCase {
    func testAppliesSteadyMainBacklightOnlyAfterCorrelatedReadback() throws {
        let challenge = (0..<56).map(UInt8.init)
        let key = NuPhySessionKey(0xa5)
        let rhythm: [UInt8] = [4, 60, 2, 1, 0, 255, 0, 0]
        let expectedMain: [UInt8] = [3, 42, 3, 0, 1, 0, 12, 34, 56]
        let transport = FakeReportTransport(
            responses: [
                sessionResponse(challenge: challenge, key: key),
                response(command: 0xd5, length: 17, address: 0, key: key, payload: signalOff + rhythm),
                response(command: 0xd6, length: 9, address: 0, key: key),
                response(command: 0xd6, length: 1, address: 1, key: key),
                response(command: 0xd5, length: 17, address: 0, key: key, payload: expectedMain + rhythm),
                sessionResponse(challenge: challenge, key: key),
                response(command: 0xd5, length: 17, address: 0, key: key, payload: expectedMain + rhythm),
            ]
        )
        let discovery = FakeDiscovery(devices: [air65()], transport: transport)
        let adapter = NuPhyIOAdapter(discovery: discovery, challenge: { challenge })
        let appearance = SignalAppearance(
            isVisible: true,
            color: SignalColor(red: 12, green: 34, blue: 56),
            brightness: SignalBrightness(percent: 42)!,
            pattern: .steady
        )

        let evidence = try adapter.applyAndVerify(.signal(appearance))

        XCTAssertTrue(evidence.protocolReadbackSucceeded)
        XCTAssertEqual(evidence.visualConfirmation, .notRequested)
        XCTAssertEqual(evidence.rhythmBefore, rhythm)
        XCTAssertEqual(evidence.rhythmAfter, rhythm)
        XCTAssertEqual(
            transport.sent[2],
            try NuPhyRequest.write(address: 0, payload: expectedMain).encoded(using: key)
        )
        XCTAssertEqual(
            transport.sent[3],
            try NuPhyRequest.write(address: 1, payload: [42]).encoded(using: key)
        )
        XCTAssertTrue(try adapter.displays(.signal(appearance)))
        XCTAssertEqual(discovery.openCount, 1)
    }

    func testSignalOffUsesZeroBrightnessAndPreservesRhythmBytes() throws {
        let challenge = Array(repeating: UInt8(7), count: 56)
        let key = NuPhySessionKey(0x5a)
        let rhythm: [UInt8] = [4, 60, 2, 1, 0, 255, 0, 0]
        let transport = FakeReportTransport(
            responses: [
                sessionResponse(challenge: challenge, key: key),
                response(command: 0xd5, length: 17, address: 0, key: key, payload: blue + rhythm),
                response(command: 0xd6, length: 9, address: 0, key: key),
                response(command: 0xd6, length: 1, address: 1, key: key),
                response(command: 0xd5, length: 17, address: 0, key: key, payload: signalOff + rhythm),
            ]
        )
        let adapter = NuPhyIOAdapter(
            discovery: FakeDiscovery(devices: [air65()], transport: transport),
            challenge: { challenge }
        )

        let evidence = try adapter.applyAndVerify(.off)

        XCTAssertEqual(evidence.mainState, signalOff)
        XCTAssertEqual(evidence.rhythmAfter, rhythm)
    }

    func testSignalOffAcceptsHardwareCanonicalizationWhenBrightnessIsZero() throws {
        let challenge = Array(repeating: UInt8(13), count: 56)
        let key = NuPhySessionKey(0x6b)
        let rhythm: [UInt8] = [4, 0, 2, 1, 0, 255, 0, 0]
        let canonicalOff: [UInt8] = [0, 0, 3, 0, 0, 0, 0, 0, 0]
        let transport = FakeReportTransport(
            responses: [
                sessionResponse(challenge: challenge, key: key),
                response(command: 0xd5, length: 17, address: 0, key: key, payload: canonicalOff + rhythm),
                response(command: 0xd5, length: 17, address: 0, key: key, payload: canonicalOff + rhythm),
                sessionResponse(challenge: challenge, key: key),
                response(command: 0xd5, length: 17, address: 0, key: key, payload: canonicalOff + rhythm),
            ]
        )
        let adapter = NuPhyIOAdapter(
            discovery: FakeDiscovery(devices: [air65()], transport: transport),
            challenge: { challenge }
        )

        let evidence = try adapter.applyAndVerify(.off)

        XCTAssertEqual(evidence.mainState, signalOff)
        XCTAssertEqual(evidence.rhythmBefore, rhythm)
        XCTAssertEqual(evidence.rhythmAfter, rhythm)
        XCTAssertTrue(try adapter.displays(.off))
        XCTAssertFalse(transport.sent.contains { $0[1] == 0xd6 })
    }

    func testNeverOpensOrWritesAnUnsupportedOrAmbiguousDevice() {
        var bluetooth = air65()
        bluetooth.bus = .bluetooth
        for devices in [[], [bluetooth], [air65(), air65()]] {
            let transport = FakeReportTransport(responses: [])
            let discovery = FakeDiscovery(devices: devices, transport: transport)
            let adapter = NuPhyIOAdapter(discovery: discovery)

            XCTAssertThrowsError(try adapter.applyAndVerify(.off))
            XCTAssertEqual(discovery.openCount, 0)
            XCTAssertTrue(transport.sent.isEmpty)
        }
    }

    func testInvalidFirmwareProtocolClaimCannotReceiveALightingWrite() {
        let challenge = Array(repeating: UInt8(9), count: 56)
        let transport = FakeReportTransport(responses: [Array(repeating: 0, count: 64)])
        let adapter = NuPhyIOAdapter(
            discovery: FakeDiscovery(devices: [air65()], transport: transport),
            challenge: { challenge }
        )

        XCTAssertThrowsError(try adapter.applyAndVerify(.off))
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0][1], 0xee)
    }

    func testRejectsReadbackThatChangesRhythmBytes() {
        let challenge = Array(repeating: UInt8(11), count: 56)
        let key = NuPhySessionKey(0x33)
        let rhythm: [UInt8] = [4, 60, 2, 1, 0, 255, 0, 0]
        var changedRhythm = rhythm
        changedRhythm[0] ^= 1
        let transport = FakeReportTransport(
            responses: [
                sessionResponse(challenge: challenge, key: key),
                response(command: 0xd5, length: 17, address: 0, key: key, payload: signalOff + rhythm),
                response(command: 0xd6, length: 9, address: 0, key: key),
                response(command: 0xd6, length: 1, address: 1, key: key),
                response(command: 0xd5, length: 17, address: 0, key: key, payload: blue + changedRhythm),
            ]
        )
        let adapter = NuPhyIOAdapter(
            discovery: FakeDiscovery(devices: [air65()], transport: transport),
            challenge: { challenge }
        )

        XCTAssertThrowsError(try adapter.applyAndVerify(.signal(LocalProfile.default.execution))) {
            XCTAssertEqual($0 as? NuPhyIOAdapterError, .rhythmLightChanged)
        }
    }

    private let blue: [UInt8] = [3, 100, 3, 0, 1, 0, 0, 0, 255]
    private let signalOff: [UInt8] = [3, 0, 3, 0, 1, 0, 0, 0, 0]

    private func air65() -> HIDDeviceDescriptor {
        HIDDeviceDescriptor(
            id: "air65-control",
            vendorID: 0x19f5,
            productID: 0x102b,
            product: "Air65 V3",
            bus: .usb,
            interfaceNumber: 3,
            usagePage: 0x0001,
            usage: 0x0000
        )
    }

    private func sessionResponse(challenge: [UInt8], key: NuPhySessionKey) -> [UInt8] {
        var report = Array(repeating: UInt8(0), count: 64)
        report[0] = 0xaa
        report[1] = 0xee
        for index in 4..<8 { report[index] = key.value }
        for index in challenge.indices { report[index + 8] = challenge[index] ^ key.value }
        report[3] = NuPhyProtocol.checksum(report)
        return report
    }

    private func response(
        command: UInt8,
        length: UInt8,
        address: UInt16,
        key: NuPhySessionKey,
        payload: [UInt8] = []
    ) -> [UInt8] {
        var report = Array(repeating: UInt8(0), count: 64)
        report[0] = 0xaa
        report[1] = command
        report[4] = length ^ key.value
        report[5] = UInt8(truncatingIfNeeded: address) ^ key.value
        report[6] = UInt8(truncatingIfNeeded: address >> 8) ^ key.value
        report[7] = key.value
        for (index, byte) in payload.enumerated() { report[index + 8] = byte ^ key.value }
        report[3] = NuPhyProtocol.checksum(report)
        return report
    }
}

private final class FakeDiscovery: Air65TransportDiscovering {
    let devices: [HIDDeviceDescriptor]
    let transport: FakeReportTransport
    private(set) var openCount = 0

    init(devices: [HIDDeviceDescriptor], transport: FakeReportTransport) {
        self.devices = devices
        self.transport = transport
    }

    func discover() throws -> [HIDDeviceDescriptor] { devices }

    func open(_ descriptor: HIDDeviceDescriptor) throws -> any Air65ReportTransport {
        openCount += 1
        return transport
    }
}

private final class FakeReportTransport: Air65ReportTransport {
    private var responses: [[UInt8]]
    private(set) var sent: [[UInt8]] = []

    init(responses: [[UInt8]]) {
        self.responses = responses
    }

    func send(_ report: [UInt8]) throws {
        sent.append(report)
    }

    func receive(timeout: TimeInterval) throws -> [UInt8]? {
        responses.isEmpty ? nil : responses.removeFirst()
    }
}
