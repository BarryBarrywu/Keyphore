import Foundation
@testable import KeyphoreCore
import XCTest

final class ExperimentalKeyboardTests: XCTestCase {
    func testAllCandidatesKeepTheirLayoutsWithoutInferredExperimentalPermission() {
        XCTAssertEqual(CandidateKeyboardModel.allCases.count, 33)
        for model in CandidateKeyboardModel.allCases {
            XCTAssertFalse(model.definition.keys.isEmpty, model.rawValue)
            XCTAssertNil(NuPhyLightingProfile.experimental(for: model), model.rawValue)
            XCTAssertFalse(ExperimentalKeyboardIdentity.isEligible(model), model.rawValue)
            XCTAssertNil(ExperimentalKeyboardIdentity(device(model)), model.rawValue)
        }
    }

    func testCandidateDiscoveryNeverOpensHIDOrSendsProbeOrLightingCommands() throws {
        for model in CandidateKeyboardModel.allCases where model != .air75V3 {
            let discovery = ExperimentalDiscovery(devices: [device(model)])
            let adapter = NuPhyIOAdapter(discovery: discovery)
            XCTAssertNil(try adapter.experimentalDevice(), model.rawValue)
            XCTAssertThrowsError(try adapter.apply(.off), model.rawValue)
            XCTAssertEqual(discovery.opens, 0, model.rawValue)
            XCTAssertTrue(discovery.transport.sent.isEmpty, model.rawValue)
        }
    }

    func testLegacyApprovalCannotEnableProbeTrialOrProductionWrites() throws {
        let root = URL(fileURLWithPath: "/private/tmp/codex-builds").appending(path: "profile-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExperimentalKeyboardStore(url: root.appending(path: "trials.json"))
        let identity = try JSONDecoder().decode(ExperimentalKeyboardIdentity.self, from: Data(#"{"productID":4134,"product":"Kick75","firmwareVersion":256,"protocolRevision":1}"#.utf8))
        XCTAssertEqual(identity.usbRevision, 256)
        XCTAssertFalse(identity.isEligible)
        for phase in ExperimentalKeyboardRecord.Phase.allTestPhases {
            let record = ExperimentalKeyboardRecord(identity: identity, phase: phase, step: 4,
                protectedState: Array(repeating: 0, count: 8), signalOffVerified: true)
            try JSONEncoder().encode([record]).write(to: store.url)
            XCTAssertThrowsError(try store.requestTrial(identity))
            XCTAssertThrowsError(try store.confirm(identity))
            XCTAssertThrowsError(try store.revoke(identity))
            let discovery = ExperimentalDiscovery(devices: [device(.kick75IO)])
            let adapter = NuPhyIOAdapter(discovery: discovery)
            adapter.experimentalStore = store
            XCTAssertThrowsError(try adapter.inspectExperimental(identity))
            XCTAssertThrowsError(try adapter.applyExperimental(.off, identity: identity))
            XCTAssertThrowsError(try adapter.apply(.off))
            let controller = ExperimentalKeyboardController(store: store, lighting: adapter)
            XCTAssertFalse(try controller.poll())
            XCTAssertEqual(discovery.opens, 0)
            XCTAssertTrue(discovery.transport.sent.isEmpty)
        }
    }

    func testVerifiedProfilesPreserveMainAndProtectedZonesAndBrightnessDifference() throws {
        for (pid, name, expectedWrites) in [(UInt16(0x102b), "Air65 V3", 2), (UInt16(0x1028), "Air75 V3", 1)] {
            var keyboard = device(.air75V3)
            keyboard.productID = pid
            keyboard.product = name
            let discovery = ExperimentalDiscovery(devices: [keyboard])
            let adapter = NuPhyIOAdapter(discovery: discovery, challenge: { Array(repeating: 7, count: 56) })
            let originalSide = Array(discovery.transport.state[9..<17])
            let behavior = LightingBehavior.signal(SignalAppearance(isVisible: true,
                color: SignalColor(red: 0, green: 0, blue: 255), brightness: SignalBrightness(percent: 30)!, pattern: .steady))
            let evidence = try adapter.applyAndVerify(behavior)
            XCTAssertTrue(evidence.protocolReadbackSucceeded)
            XCTAssertEqual(evidence.rhythmAfter, originalSide)
            let writes = discovery.transport.sent.filter { $0[1] == 0xd6 }
            XCTAssertEqual(writes.count, expectedWrites)
            XCTAssertEqual(writes[0][4] ^ 0xa5, 9)
            XCTAssertEqual(writes[0][5] ^ 0xa5, 0)
            if expectedWrites == 2 {
                XCTAssertEqual(writes[1][4] ^ 0xa5, 1)
                XCTAssertEqual(writes[1][5] ^ 0xa5, 1)
            }
            XCTAssertTrue(try adapter.displays(behavior))
        }
    }

    private func device(_ model: CandidateKeyboardModel) -> HIDDeviceDescriptor {
        HIDDeviceDescriptor(id: "candidate", vendorID: 0x19f5, productID: model.definition.productID,
            product: model.rawValue, bus: .usb, interfaceNumber: 3, usagePage: 1, usage: 0, usbRevision: 256)
    }
}

private extension ExperimentalKeyboardRecord.Phase {
    static let allTestPhases: [Self] = [.available, .requested, .testing, .awaitingConfirmation, .enabled, .revoking, .disabled, .failed]
}

private final class ExperimentalDiscovery: Air65TransportDiscovering {
    var devices: [HIDDeviceDescriptor]
    var opens = 0
    let transport = ExperimentalTransport()
    init(devices: [HIDDeviceDescriptor]) { self.devices = devices }
    func discover() throws -> [HIDDeviceDescriptor] { devices }
    func open(_ descriptor: HIDDeviceDescriptor) throws -> any Air65ReportTransport {
        opens += 1
        return transport
    }
    func resetDiscoveryState() {}
}

private final class ExperimentalTransport: Air65ReportTransport {
    var sent: [[UInt8]] = []
    var pending: [UInt8]?
    var corruptNextWrite = false
    var state: [UInt8] = [3, 0, 3, 0, 1, 0, 0, 0, 0, 0, 60, 2, 1, 0, 255, 0, 0]
    let key: UInt8 = 0xa5
    func send(_ report: [UInt8]) throws {
        sent.append(report)
        var response = report
        response[0] = 0xaa
        if report[1] == 0xee {
            for i in 4..<8 { response[i] = key }
            for i in 8..<64 { response[i] = report[i] ^ key }
        } else {
            let length = Int(report[4] ^ key)
            let address = Int(report[5] ^ key)
            if report[1] == 0xd6 {
                for i in 0..<length { state[address + i] = report[8 + i] ^ key }
                if corruptNextWrite { state[8] = 77; corruptNextWrite = false }
            } else {
                for i in 0..<length { response[8 + i] = state[address + i] ^ key }
            }
        }
        response[3] = NuPhyProtocol.checksum(response)
        pending = response
    }
    func receive(timeout: TimeInterval) throws -> [UInt8]? {
        defer { pending = nil }
        return pending
    }
}
