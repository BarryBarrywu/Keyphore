import KeyphoreCore
import XCTest

final class NuPhyIOAdapterAcceptanceTests: XCTestCase {
    func testProductionAdapterUsesAir75WriteAndReacquiresModelAfterInterruption() throws {
        let challenge = Array(repeating: UInt8(7), count: 56)
        let key = NuPhySessionKey(0x5a)
        let side: [UInt8] = [0, 60, 2, 1, 0, 255, 0, 0]
        let expected: [UInt8] = [3, 30, 3, 0, 1, 0, 0, 0, 255]
        let transport = FakeReportTransport(responses: [
            sessionResponse(challenge: challenge, key: key),
            response(command: 0xd5, length: 17, address: 0, key: key, payload: signalOff + side),
            response(command: 0xd6, length: 9, address: 0, key: key),
            response(command: 0xd5, length: 17, address: 0, key: key, payload: expected + side),
            sessionResponse(challenge: challenge, key: key),
            response(command: 0xd5, length: 17, address: 0, key: key, payload: signalOff + side),
            response(command: 0xd6, length: 9, address: 0, key: key),
            response(command: 0xd6, length: 1, address: 1, key: key),
            response(command: 0xd5, length: 17, address: 0, key: key, payload: expected + side),
        ])
        var device = air65()
        device.productID = 0x1028
        device.product = "Air75 V3"
        let discovery = FakeDiscovery(devices: [device], transport: transport)
        let adapter = NuPhyIOAdapter(discovery: discovery, challenge: { challenge })
        let behavior = LightingBehavior.signal(SignalAppearance(
            isVisible: true, color: SignalColor(red: 0, green: 0, blue: 255),
            brightness: SignalBrightness(percent: 30)!, pattern: .steady
        ))
        XCTAssertTrue(try adapter.applyAndVerify(behavior).protocolReadbackSucceeded)
        XCTAssertEqual(adapter.connectedModel, .air75V3)
        XCTAssertEqual(transport.sent.map { $0[1] }, [0xee, 0xd5, 0xd6, 0xd5])
        adapter.invalidateTransport()
        XCTAssertNil(adapter.connectedModel)
        discovery.devices = [air65()]
        XCTAssertTrue(try adapter.applyAndVerify(behavior).protocolReadbackSucceeded)
        XCTAssertEqual(adapter.connectedModel, .air65V3)
        XCTAssertEqual(discovery.openCount, 2)
        XCTAssertEqual(transport.sent[7], try NuPhyRequest.write(address: 1, payload: [30]).encoded(using: key))
    }

    func testAir75PreviewMismatchStopsColorsAndAttemptsSignalOff() throws {
        let challenge = Array(repeating: UInt8(7), count: 56)
        let key = NuPhySessionKey(0x5a)
        let side: [UInt8] = [0, 60, 2, 1, 0, 255, 0, 0]
        let actual: [UInt8] = [3, 20, 3, 0, 1, 0, 0, 0, 255]
        let transport = FakeReportTransport(responses: [
            sessionResponse(challenge: challenge, key: key),
            response(command: 0xd5, length: 17, address: 0, key: key, payload: signalOff + side),
            response(command: 0xd6, length: 9, address: 0, key: key),
            response(command: 0xd5, length: 17, address: 0, key: key, payload: actual + side),
            sessionResponse(challenge: challenge, key: key),
            response(command: 0xd5, length: 17, address: 0, key: key, payload: actual + side),
            response(command: 0xd6, length: 9, address: 0, key: key),
            response(command: 0xd5, length: 17, address: 0, key: key, payload: signalOff + side),
        ])
        let device = HIDDeviceDescriptor(
            id: "air75-control", vendorID: 0x19f5, productID: 0x1028,
            product: "Air75 V3", bus: .usb, interfaceNumber: 3, usagePage: 1, usage: 0
        )
        let adapter = NuPhyIOAdapter(
            discovery: FakeDiscovery(devices: [device], transport: transport), challenge: { challenge }
        )
        XCTAssertThrowsError(try adapter.previewAir75MainBacklight { _ in XCTFail("No color verified") }) {
            XCTAssertEqual($0 as? NuPhyIOAdapterError, .air75ReadbackMismatch(
                expected: [3, 30, 3, 0, 1, 0, 0, 0, 255], actual: actual + side
            ))
        }
        XCTAssertEqual(transport.sent.count, 8)
        XCTAssertEqual(transport.sent[6], try NuPhyRequest.write(address: 0, payload: signalOff).encoded(using: key))
    }

    func testAir75AcceptancePreviewPreservesSideStateAndEndsOff() throws {
        let challenge = Array(repeating: UInt8(7), count: 56)
        let key = NuPhySessionKey(0x5a)
        let side: [UInt8] = [0, 60, 2, 1, 0, 255, 0, 0]
        let states: [[UInt8]] = [
            [3, 30, 3, 0, 1, 0, 0, 0, 255],
            [3, 30, 3, 0, 1, 0, 255, 132, 0],
            [3, 30, 3, 0, 1, 0, 0, 255, 0], signalOff,
        ]
        var responses: [[UInt8]] = []
        var initial: [UInt8] = [3, 100, 3, 0, 1, 0, 255, 255, 255]
        for state in states {
            responses += [
                sessionResponse(challenge: challenge, key: key),
                response(command: 0xd5, length: 17, address: 0, key: key, payload: initial + side),
                response(command: 0xd6, length: 9, address: 0, key: key),
                response(command: 0xd5, length: 17, address: 0, key: key, payload: state + side),
            ]
            initial = state
        }
        let transport = FakeReportTransport(responses: responses)
        let device = HIDDeviceDescriptor(
            id: "air75-control", vendorID: 0x19f5, productID: 0x1028,
            product: "Air75 V3", bus: .usb, interfaceNumber: 3, usagePage: 1, usage: 0
        )
        let adapter = NuPhyIOAdapter(
            discovery: FakeDiscovery(devices: [device], transport: transport), challenge: { challenge }
        )
        var steps: [String] = []
        try adapter.previewAir75MainBacklight { steps.append($0) }
        XCTAssertEqual(steps, ["blue", "orange", "green", "off"])
        let writes = transport.sent.filter { $0[1] == 0xd6 }
        XCTAssertEqual(writes.count, 4)
        for packet in writes {
            XCTAssertEqual(packet[5] ^ key.value, 0)
            XCTAssertEqual(packet[4] ^ key.value, 9)
            XCTAssertEqual(packet[6] ^ key.value, 0)
        }
    }

    func testAir75InspectionOnlyExchangesSessionAndReadsState() throws {
        let challenge = Array(repeating: UInt8(7), count: 56)
        let key = NuPhySessionKey(0x5a)
        let state = Array(UInt8(0)...UInt8(16))
        let device = HIDDeviceDescriptor(
            id: "air75-control", vendorID: 0x19f5, productID: 0x1028,
            product: "Air75 V3", bus: .usb, interfaceNumber: 3, usagePage: 1, usage: 0
        )
        let transport = FakeReportTransport(responses: [
            sessionResponse(challenge: challenge, key: key),
            response(command: 0xd5, length: 17, address: 0, key: key, payload: state),
        ])
        let discovery = FakeDiscovery(devices: [device], transport: transport)
        let adapter = NuPhyIOAdapter(discovery: discovery, challenge: { challenge })
        XCTAssertEqual(try adapter.inspectAir75MainAndSideState(), state)
        XCTAssertEqual(transport.sent.map { $0[1] }, [0xee, 0xd5])
        let sends = transport.sent.count
        discovery.devices = [device, device]
        XCTAssertThrowsError(try adapter.inspectAir75MainAndSideState())
        discovery.devices = [air65()]
        XCTAssertThrowsError(try adapter.inspectAir75MainAndSideState())
        XCTAssertEqual(discovery.openCount, 1)
        XCTAssertEqual(transport.sent.count, sends)
    }

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
        var air75 = air65()
        air75.productID = 0x1028
        air75.product = "Air75 V3"
        var kick75 = air65()
        kick75.productID = 0x1026
        kick75.product = "Kick75"
        for devices in [[], [bluetooth], [kick75], [air75, air65()], [air65(), air65()]] {
            let transport = FakeReportTransport(responses: [])
            let discovery = FakeDiscovery(devices: devices, transport: transport)
            let adapter = NuPhyIOAdapter(discovery: discovery)

            XCTAssertThrowsError(try adapter.applyAndVerify(.off))
            XCTAssertEqual(discovery.openCount, 0)
            XCTAssertTrue(transport.sent.isEmpty)
        }
    }

    func testEveryCatalogCandidateRefusesHIDOpenAndLightingWrites() {
        for model in CandidateKeyboardModel.allCases where model != .air75V3 {
            var descriptor = air65()
            descriptor.productID = model.definition.productID
            descriptor.product = model.rawValue
            let transport = FakeReportTransport(responses: [])
            let discovery = FakeDiscovery(devices: [descriptor], transport: transport)
            let adapter = NuPhyIOAdapter(discovery: discovery)
            XCTAssertThrowsError(try adapter.applyAndVerify(.off), model.rawValue)
            XCTAssertEqual(discovery.openCount, 0, model.rawValue)
            XCTAssertTrue(transport.sent.isEmpty, model.rawValue)
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

    func testRecoveryInvalidatesTheOwnedTransportBeforeRediscovery() throws {
        let challenge = Array(repeating: UInt8(17), count: 56)
        let key = NuPhySessionKey(0x47)
        let rhythm: [UInt8] = [4, 60, 2, 1, 0, 255, 0, 0]
        let successfulExchange = [
            sessionResponse(challenge: challenge, key: key),
            response(
                command: 0xd5,
                length: 17,
                address: 0,
                key: key,
                payload: signalOff + rhythm
            ),
            response(
                command: 0xd5,
                length: 17,
                address: 0,
                key: key,
                payload: signalOff + rhythm
            ),
        ]
        let transport = FakeReportTransport(responses: successfulExchange + successfulExchange)
        let discovery = FakeDiscovery(devices: [air65()], transport: transport)
        let adapter = NuPhyIOAdapter(discovery: discovery, challenge: { challenge })

        try adapter.apply(.off)
        discovery.isStale = true
        adapter.invalidateTransport()
        try adapter.apply(.off)

        XCTAssertEqual(discovery.openCount, 2)
        XCTAssertEqual(discovery.invalidationCount, 1)
    }

    func testUnavailableDeviceRecoversThroughValidationAndAggregateReplayWithoutPreview() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DurableStatusStore(url: directory.appending(path: "status.json"))
        let healthStore = KeyboardHealthStore(
            url: directory.appending(path: "keyboard-health.json")
        )
        try store.recordSignal(
            ownerID: SignalOwnerID(product: "codex", sessionID: "session", agentID: "main"),
            turnID: "turn",
            signal: .execution,
            expiresAt: .milliseconds(3_600_000),
            replacingSession: true,
            lockBudget: .milliseconds(100)
        )
        let statusBeforeRecovery = try store.load()
        let challenge = Array(repeating: UInt8(19), count: 56)
        let key = NuPhySessionKey(0x31)
        let rhythm: [UInt8] = [4, 60, 2, 1, 0, 255, 0, 0]
        let transport = FakeReportTransport(
            responses: [
                sessionResponse(challenge: challenge, key: key),
                response(
                    command: 0xd5,
                    length: 17,
                    address: 0,
                    key: key,
                    payload: signalOff + rhythm
                ),
                response(command: 0xd6, length: 9, address: 0, key: key),
                response(command: 0xd6, length: 1, address: 1, key: key),
                response(
                    command: 0xd5,
                    length: 17,
                    address: 0,
                    key: key,
                    payload: blue + rhythm
                ),
            ]
        )
        let discovery = FakeDiscovery(devices: [air65()], transport: transport)
        discovery.isStale = true
        let companion = KeyphoreCompanion(
            store: store,
            profile: .default,
            lighting: NuPhyIOAdapter(discovery: discovery, challenge: { challenge }),
            keyboardHealthStore: healthStore
        )
        let recovery = CompanionRecoveryController(companion: companion)

        XCTAssertThrowsError(try recovery.poll(at: .milliseconds(100)))
        XCTAssertEqual(healthStore.load(at: .milliseconds(100)), .disconnected)

        try recovery.poll(at: .milliseconds(200))

        XCTAssertEqual(try store.load(), statusBeforeRecovery)
        XCTAssertEqual(healthStore.load(at: .milliseconds(200)), .connected(protocolHealthy: true, model: .air65V3))
        XCTAssertEqual(discovery.invalidationCount, 1)
        XCTAssertEqual(discovery.openCount, 1)
        XCTAssertEqual(transport.sent.map { $0[1] }, [0xee, 0xd5, 0xd6, 0xd6, 0xd5])
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
    var devices: [HIDDeviceDescriptor]
    var isStale = false
    let transport: FakeReportTransport
    private(set) var openCount = 0
    private(set) var invalidationCount = 0

    init(devices: [HIDDeviceDescriptor], transport: FakeReportTransport) {
        self.devices = devices
        self.transport = transport
    }

    func discover() throws -> [HIDDeviceDescriptor] { isStale ? [] : devices }

    func open(_ descriptor: HIDDeviceDescriptor) throws -> any Air65ReportTransport {
        openCount += 1
        return transport
    }

    func resetDiscoveryState() {
        invalidationCount += 1
        isStale = false
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
