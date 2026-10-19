import Foundation
import Darwin
import KeyphoreCore

let vendorLabels: [String] = ["All Off", "Solid Color", "Gradient Up/Down", "Gradient Left/Right", "Breathing", "Band Sat.", "Band Val.", "Pinwheel Sat.", "Pinwheel Val.", "Spiral Sat.", "Spiral Val.", "Cycle All", "Cycle Left/Right", "Cycle Up/Down", "Rainbow Moving Chevron", "Cycle Out/In", "Cycle Out/In Dual", "Cycle Pinwheel", "Cycle Spiral", "Dual Beacon", "Rainbow Beacon", "Rainbow Pinwheels", "Raindrops", "Jellybean Raindrops", "Hue Breathing", "Hue Pendulum", "Hue Wave", "Typing Heatmap", "Digital Rain", "Reactive Simple", "Reactive", "Reactive Wide", "Reactive Multiwide", "Reactive Cross", "Reactive Multicross", "Reactive Nexus", "Reactive MultiNexus", "Splash", "MultiSplash", "Solid Splash", "Solid MultiSplash"]
let definitionSHA256 = "5c159cd4f219b8556e44ecc5aaecbbc1b905dcb69b4ad0ff3009f4f5f7fa7dbe"

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

final class Trace {
    let start = DispatchTime.now().uptimeNanoseconds
    var events: [[String: Any]] = []
    func add(_ kind: String, _ fields: [String: Any] = [:]) {
        var event = fields
        event["kind"] = kind
        event["elapsedMs"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        event["unixTimeMs"] = Date().timeIntervalSince1970 * 1_000
        events.append(event)
    }
}

final class TracedTransport: Air65ReportTransport {
    let base: any Air65ReportTransport
    let trace: Trace
    init(_ base: any Air65ReportTransport, trace: Trace) { self.base = base; self.trace = trace }
    func send(_ report: [UInt8]) throws {
        guard report.count == 32,
              report[0] == 1 || ([7, 8].contains(report[0]) && report[1] == 3 && (1...4).contains(report[2])) else {
            throw ProbeFailure("Refused SAVE, keymap, side channel or unexpected output report")
        }
        if report[0] == 7 && report[2] == 2 && report[3] > 40 {
            throw ProbeFailure("Refused an effect outside the supplied VIA definition")
        }
        trace.add("TX", ["bytes": report])
        do { try base.send(report) }
        catch { trace.add("TX-error", ["error": String(describing: error)]); throw error }
    }
    func receive(timeout: TimeInterval) throws -> [UInt8]? {
        do {
            let response = try base.receive(timeout: timeout)
            trace.add("RX", ["bytes": response as Any? ?? NSNull(), "timeoutSeconds": timeout])
            return response
        } catch { trace.add("RX-error", ["error": String(describing: error)]); throw error }
    }
}

final class TracedDiscovery: Air65TransportDiscovering {
    let base = SystemAir65TransportDiscovery()
    let trace: Trace
    var pinnedID: String?
    init(trace: Trace) { self.trace = trace }
    func discover() throws -> [HIDDeviceDescriptor] {
        let devices = try base.discover()
        let matches = devices.filter { SupportedKeyboardModel.identify($0) == .air75V2 }
        guard matches.count == 1 else { throw ProbeFailure("Require exactly one wired Air75 V2 raw-HID interface") }
        let id = matches[0].id
        guard pinnedID == nil || pinnedID == id else { throw ProbeFailure("V2 device identity changed during probe") }
        pinnedID = id
        trace.add("discover", ["pinnedV2RegistryID": id])
        return devices
    }
    func open(_ descriptor: HIDDeviceDescriptor) throws -> any Air65ReportTransport {
        guard SupportedKeyboardModel.identify(descriptor) == .air75V2, descriptor.id == pinnedID else {
            throw ProbeFailure("Refused to open a different keyboard")
        }
        trace.add("open", ["registryID": descriptor.id])
        return try TracedTransport(base.open(descriptor), trace: trace)
    }
    func resetDiscoveryState() { trace.add("resetDiscovery"); base.resetDiscoveryState() }
}

func progress(_ fields: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data([10]))
    }
}

func runProbe() -> Int32 {
    let trace = Trace()
    let support = KeyphoreRuntimePaths.supportDirectory()
    let gate = QuitGateStore(url: KeyphoreRuntimePaths.quitGateURL())
    let ownership = LightingOwnershipStore(url: support.appending(path: "lighting-ownership.json"))
    let effects = NativeLightingEffect.viaCatalog
    var lease: CompanionProcessLease?
    var adapter: NuPhyIOAdapter?
    var ownsBacklight = false
    var result: [String: Any] = ["probe": "V2-all-41-effects", "definitionSHA256": definitionSHA256,
        "brightnessPercent": 30, "requestedBrightnessByte": 77, "brightnessTolerance": 3,
        "requestedColor": "#00FFAE", "requestedHue": 114, "requestedSaturation": 255,
        "speedLevel": 4, "requestedSpeedByte": 255, "visualConfirmation": "notRequested"]
    var stages: [[String: Any]] = []
    var attempted: [Int] = []
    var passed: [Int] = []
    var failed = false
    do {
        guard vendorLabels.count == 41, effects.count == 41,
              effects.enumerated().allSatisfy({ $0.element.viaWireID == UInt8($0.offset) }),
              effects[0].isOff, !effects.dropFirst().contains(where: { $0.isOff }) else {
            throw ProbeFailure("Core catalog does not match the supplied 0...40 VIA contract")
        }
        guard gate.isActive else { throw ProbeFailure("Quit gate must already be active") }
        lease = try CompanionProcessLease.acquire(url: support.appending(path: "companion.lock"))
        guard gate.isActive, FileManager.default.fileExists(atPath: ownership.url.path),
              try ownership.load() == .empty else {
            throw ProbeFailure("Require an existing empty ownership journal with no model")
        }
        let driver = NuPhyIOAdapter(discovery: TracedDiscovery(trace: trace))
        adapter = driver
        try driver.selectTarget(.air75V2)
        let initial = try driver.inspectAir75V2State()
        result["initialMainState"] = initial
        guard initial.count == 5, initial[1] == 0 else {
            throw ProbeFailure("Initial main effect is not off; refusing to overwrite existing lighting")
        }
        guard gate.isActive, try ownership.load() == .empty else {
            throw ProbeFailure("Recovery preconditions changed before first write")
        }
        try ownership.save(LightingOwnershipRecord(model: .air75V2, zones: [.backlight]))
        ownsBacklight = true
        for (mode, effect) in effects.enumerated() {
            attempted.append(mode)
            var stage: [String: Any] = ["modeID": mode, "vendorLabel": vendorLabels[mode],
                                       "effect": effect.rawValue, "visualConfirmation": "notRequested"]
            let began = DispatchTime.now().uptimeNanoseconds
            trace.add("stage", ["modeID": mode, "vendorLabel": vendorLabels[mode]])
            progress(["modeID": mode, "label": vendorLabels[mode], "phase": "started"])
            do {
                guard gate.isActive else { throw ProbeFailure("Quit gate was cleared during probe") }
                let appearance = ZoneAppearance(effect: effect, color: SignalColor(red: 0, green: 255, blue: 174),
                    brightness: SignalBrightness(percent: 30)!, speed: LightingSpeed(level: 4)!)
                let evidence = try driver.applyAndVerify(LightingBehavior(backlight: .signal(appearance), strip: .unmanaged))
                let state = evidence.mainState
                stage["observedMainState"] = state
                guard evidence.protocolReadbackSucceeded, state.count == 5, state[1] == UInt8(mode) else {
                    throw ProbeFailure("Returned state does not verify the requested mode")
                }
                if mode != 0 {
                    guard abs(Int(state[0]) - 77) <= 3, state[2] == 255, state[3] == 114, state[4] == 255 else {
                        throw ProbeFailure("Non-Off HSV/speed/normalized-brightness verification failed")
                    }
                }
                stage["protocolReadbackSucceeded"] = true
                stage["elapsedMs"] = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                stages.append(stage)
                passed.append(mode)
                progress(["modeID": mode, "phase": "passed", "observedMainState": state])
            } catch {
                stage["protocolReadbackSucceeded"] = false
                stage["error"] = String(describing: error)
                stage["elapsedMs"] = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                trace.add("postFailureInspectGETOnly")
                do { stage["observedAfterFailure"] = try driver.inspectAir75V2State() }
                catch { stage["postFailureInspectError"] = String(describing: error) }
                stages.append(stage)
                progress(["modeID": mode, "phase": "failed", "error": String(describing: error)])
                throw error
            }
        }
    } catch {
        failed = true
        result["error"] = String(describing: error)
    }
    if ownsBacklight, let adapter {
        trace.add("cleanupOff")
        do {
            let evidence = try adapter.applyAndVerify(.off)
            result["offObservedMainState"] = evidence.mainState
            guard evidence.protocolReadbackSucceeded, evidence.mainState.count == 5, evidence.mainState[1] == 0 else {
                throw ProbeFailure("Off readback was not verified")
            }
            try ownership.save(.empty)
            result["ownershipClearedAfterVerifiedOff"] = true
        } catch {
            failed = true
            result["cleanupError"] = String(describing: error)
            result["ownershipClearedAfterVerifiedOff"] = false
        }
    }
    result["stages"] = stages
    result["attemptedModeIDs"] = attempted
    result["passedModeIDs"] = passed
    result["unexecutedModeIDs"] = (0...40).filter { !attempted.contains($0) }
    result["transcript"] = trace.events
    result["success"] = !failed && passed.count == 41
    withExtendedLifetime(lease) {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        } else { print("{\"error\":\"Could not serialize probe result\"}") }
    }
    return failed ? 1 : 0
}

exit(runProbe())
