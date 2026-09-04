import Foundation
import KeyphoreCore

private let arguments = CommandLine.arguments.dropFirst()
private let store = DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL())
private let profileStore = LocalProfileStore(url: KeyphoreRuntimePaths.localProfileURL())
private let previewStore = SignalPreviewStore(url: KeyphoreRuntimePaths.signalPreviewURL())

switch arguments.first {
case "release-hook-digest":
    print(HookDefinition.reviewedReleaseDigest)
case "hook":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 1_048_576 else {
        exit(1)
    }
    guard
        (try? ProductionHookHandler(
            store: store,
            quitGate: QuitGateStore(url: KeyphoreRuntimePaths.quitGateURL()),
            configuredStateURL: KeyphoreRuntimePaths.configuredStateURL(),
            profileProvider: { profileStore.loadOrDefault() }
        ).handle(input)) != nil
    else {
        exit(1)
    }
case "companion":
    guard
        let lease = try? CompanionProcessLease.acquire(
            url: KeyphoreRuntimePaths.supportDirectory().appending(path: "companion.lock")
        )
    else {
        exit(1)
    }
    let healthStore = KeyboardHealthStore(url: KeyphoreRuntimePaths.keyboardHealthURL())
    let lighting = NuPhyIOAdapter(discovery: SystemAir65TransportDiscovery())
    let experimentalStore = ExperimentalKeyboardStore()
    lighting.experimentalStore = experimentalStore
    if let acceptanceMode = arguments.dropFirst().first,
        ["--inspect-air75", "--preview-air75", "--trace-air75"].contains(acceptanceMode) {
        do {
            try withExtendedLifetime(lease) {
                if acceptanceMode == "--inspect-air75" {
                    let bytes = try lighting.inspectAir75MainAndSideState()
                    print(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
                } else {
                    let trace: ((String, [UInt8]) -> Void)? = acceptanceMode == "--trace-air75" ? { stage, bytes in
                        print("Air75 \(stage): \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    } : nil
                    try lighting.previewAir75MainBacklight(trace: trace) { step in
                        print("Air75 \(step): main readback matched; side state unchanged")
                        if step != "off" {
                            RunLoop.current.run(until: Date().addingTimeInterval(5))
                        }
                    }
                }
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Air75 inspection failed: \(error)\n".utf8))
            exit(1)
        }
    }
    let companion = KeyphoreCompanion(
        store: store,
        profileProvider: { try profileStore.load() },
        lighting: lighting,
        keyboardHealthStore: healthStore,
        previewStore: previewStore,
        signalOffAcknowledgement: SignalOffAcknowledgementStore(
            url: KeyphoreRuntimePaths.signalOffAcknowledgementURL()
        )
    )
    let recovery = CompanionRecoveryController(companion: companion)
    let powerEvents = SystemPowerEventMonitor { event in
        try? recovery.handle(event)
    }
    let experiments = ExperimentalKeyboardController(
        store: experimentalStore, lighting: lighting, healthStore: healthStore,
        signalOffAcknowledgement: SignalOffAcknowledgementStore(url: KeyphoreRuntimePaths.signalOffAcknowledgementURL())
    )
    var lastExperimentCheck = ContinuousClock.now - .seconds(1)
    var holdsExperimentalRuntime = false
    var lastHealthCheck = ContinuousClock.now
    while true {
        if lastExperimentCheck.duration(to: .now) >= .seconds(1) {
            do {
                holdsExperimentalRuntime = try experiments.poll(
                    quitting: QuitGateStore(url: KeyphoreRuntimePaths.quitGateURL()).isActive
                )
            } catch { holdsExperimentalRuntime = true }
            lastExperimentCheck = .now
        }
        if !holdsExperimentalRuntime { try? recovery.poll() }
        if !holdsExperimentalRuntime, lastHealthCheck.duration(to: .now) >= .seconds(1) {
            try? recovery.healthCheck()
            lastHealthCheck = .now
        }
        withExtendedLifetime((powerEvents, lease)) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
default:
    exit(64)
}
