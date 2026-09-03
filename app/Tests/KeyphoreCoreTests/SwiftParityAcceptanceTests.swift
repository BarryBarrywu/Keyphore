import Foundation
import KeyphoreCore
import XCTest

@MainActor
final class SwiftParityAcceptanceTests: XCTestCase {
    func testCanonicalRustScenariosThroughProductionHookAndCompanion() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/fixtures/swift-parity.json")
        let fixture = try JSONDecoder().decode(ParityFixture.self, from: Data(contentsOf: source))
        var observations: [ParityObservation] = []
        for scenario in fixture.scenarios {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = DurableStatusStore(url: directory.appending(path: "status.json"))
            let hook = ProductionHookHandler(store: store)
            let keyboard = ParityKeyboard(rhythm: fixture.rhythm)
            let adapter = NuPhyIOAdapter(discovery: keyboard)
            var companion = KeyphoreCompanion(store: store, profile: .default, lighting: adapter)
            var expiry: SignalExpiry?
            var recovery = CompanionRecoveryController(companion: companion)
            let epoch = StatusTimestamp.now.millisecondsSince1970
            for (index, step) in scenario.steps.enumerated() {
                let now = StatusTimestamp.milliseconds(epoch + step.at)
                let writeStart = keyboard.writes.count
                if let event = step.event {
                    try hook.handle(JSONEncoder().encode(event), receivedAt: now)
                }
                if step.capture_expiry == true {
                    expiry = try XCTUnwrap(store.load().expiries.first)
                }
                if step.restart == true {
                    companion = KeyphoreCompanion(store: store, profile: .default, lighting: adapter)
                    recovery = CompanionRecoveryController(companion: companion)
                    keyboard.state.replaceSubrange(0..<9, with: Array(repeating: 0, count: 9))
                }
                if step.power == "sleep" { try recovery.handle(.willSleep, at: now) }
                if step.power == "wake" { try recovery.handle(.didWake, at: now) }
                if step.reconnect == true {
                    keyboard.state.replaceSubrange(0..<9, with: Array(repeating: 0, count: 9))
                    try companion.transportInterrupted(at: now)
                }
                if step.fire_expiry == true {
                    try companion.handle(expiry: XCTUnwrap(expiry), at: now)
                } else {
                    try recovery.poll(at: now)
                }
                let displayedSignal = try XCTUnwrap(fixture.main_states.first {
                    $0.value == Array(keyboard.state.prefix(9))
                }?.key)
                XCTAssertEqual(displayedSignal, step.displayed_signal, "\(scenario.id) step \(index)")
                XCTAssertEqual(Array(keyboard.state.prefix(9)), fixture.main_states[displayedSignal])
                XCTAssertEqual(Array(keyboard.state.suffix(8)), fixture.rhythm)
                let aggregate: String
                switch lifecycleSnapshot(outcome: try store.outcome(at: now),
                    lighting: RecordingMenuLightingAdapter()).currentSignal {
                case .attention: aggregate = "attention"
                case .execution: aggregate = "execution"
                case .completion: aggregate = "completion"
                case .signalOff: aggregate = "off"
                }
                XCTAssertEqual(aggregate, step.aggregate)
                let persisted = try String(contentsOf: store.url, encoding: .utf8)
                for marker in fixture.private_markers {
                    XCTAssertFalse(persisted.contains(marker))
                }
                let owners = try store.load().owners.map { owner in
                    ParityOwner(session: owner.id.sessionID, agent: owner.id.agentID,
                        product: owner.id.product, turn: owner.turnID, signal: owner.signal.rawValue,
                        generation: owner.generation, expires_at: owner.expiresAt.millisecondsSince1970 - epoch)
                }
                observations.append(ParityObservation(scenario: scenario.id, step: index,
                    aggregate: aggregate, displayed_signal: displayedSignal, owners: owners, main: Array(keyboard.state.prefix(9)),
                    rhythm: Array(keyboard.state.suffix(8)), privacy: "passed",
                    lighting_packets: Array(keyboard.writes.dropFirst(writeStart))))
            }
        }
        if let directory = ProcessInfo.processInfo.environment["KEYPHORE_PARITY_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(observations).write(to: URL(fileURLWithPath: directory)
                .appending(path: "swift-parity.json"))
        }
    }
}

private struct ParityFixture: Decodable {
    let main_states: [String: [UInt8]]
    let rhythm: [UInt8]
    let private_markers: [String]
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let steps: [Step]
    }
    struct Step: Decodable {
        let at: UInt64
        let event: [String: String]?
        let aggregate: String
        let displayed_signal: String
        let capture_expiry: Bool?
        let fire_expiry: Bool?
        let restart: Bool?
        let reconnect: Bool?
        let power: String?
    }
}

private struct ParityOwner: Encodable {
    let session, agent, product, turn, signal: String
    let generation, expires_at: UInt64
}

private struct ParityObservation: Encodable {
    let scenario: String
    let step: Int
    let aggregate: String
    let displayed_signal: String
    let owners: [ParityOwner]
    let main, rhythm: [UInt8]
    let privacy: String
    let lighting_packets: [[UInt8]]
}

private final class ParityKeyboard: Air65TransportDiscovering, Air65ReportTransport {
    var state: [UInt8]
    private var responses: [[UInt8]] = []
    var writes: [[UInt8]] = []

    init(rhythm: [UInt8]) {
        state = [3, 40, 2, 0, 1, 0, 170, 187, 204] + rhythm
    }

    func discover() -> [HIDDeviceDescriptor] {
        [HIDDeviceDescriptor(id: "fixture", vendorID: 0x19f5, productID: 0x102b,
            product: "Air65 V3", bus: .usb, interfaceNumber: 3, usagePage: 1, usage: 0)]
    }

    func open(_ descriptor: HIDDeviceDescriptor) -> any Air65ReportTransport { self }
    func resetDiscoveryState() {}

    func send(_ request: [UInt8]) throws {
        if request[1] == 0xd6 { writes.append(request) }
        let key: UInt8 = 0xa5
        var response = Array(repeating: UInt8(0), count: 64)
        response[0] = 0xaa
        response[1] = request[1]
        if request[1] == 0xee {
            response.replaceSubrange(4..<8, with: Array(repeating: key, count: 4))
            for index in 8..<64 { response[index] = request[index] ^ key }
        } else {
            response.replaceSubrange(4..<8, with: request[4..<8])
            let length = Int(request[4] ^ key)
            let address = Int(request[5] ^ key) | (Int(request[6] ^ key) << 8)
            switch request[1] {
            case 0xd5:
                for index in 0..<length { response[8 + index] = state[address + index] ^ key }
            case 0xd6:
                guard address + length <= 9 else { throw NuPhyIOAdapterError.rhythmLightChanged }
                for index in 0..<length { state[address + index] = request[8 + index] ^ key }
            default: throw NuPhyProtocolError.commandMismatch
            }
        }
        response[3] = NuPhyProtocol.checksum(response)
        responses.append(response)
    }

    func receive(timeout: TimeInterval) -> [UInt8]? {
        responses.isEmpty ? nil : responses.removeFirst()
    }
}
