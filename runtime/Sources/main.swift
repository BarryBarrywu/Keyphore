import Foundation
import KeyphoreCore

private let arguments = CommandLine.arguments.dropFirst()
private let store = DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL())
private let profileStore = KeyboardProfileStore(directory: KeyphoreRuntimePaths.keyboardProfilesDirectory())
private let ownershipStore = LightingOwnershipStore(url: KeyphoreRuntimePaths.supportDirectory().appending(path: "lighting-ownership.json"))
private let previewStore = SignalPreviewStore(url: KeyphoreRuntimePaths.signalPreviewURL())

switch arguments.first {
case "release-hook-digest":
    print(HookDefinition.reviewedReleaseDigest)
case "hook":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 1_048_576 else {
        exit(1)
    }
    do {
        if let sourceName = arguments.dropFirst().first {
            guard arguments.count == 2, let source = AgentSource(rawValue: sourceName), source != .codex else {
                exit(64)
            }
            try AgentHookHandler(
                store: store, source: source,
                consentStore: AgentIntegrationConsentStore(url: KeyphoreRuntimePaths.agentIntegrationsURL()),
                runtimeURL: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                quitGate: QuitGateStore(url: KeyphoreRuntimePaths.quitGateURL()),
                completionDurationProvider: { profileStore.completionDisplayDuration(ownership: ownershipStore) }
            ).handle(input)
        } else {
            try ProductionHookHandler(
                store: store,
                quitGate: QuitGateStore(url: KeyphoreRuntimePaths.quitGateURL()),
                configuredStateURL: KeyphoreRuntimePaths.configuredStateURL(),
                completionDurationProvider: { profileStore.completionDisplayDuration(ownership: ownershipStore) }
            ).handle(input)
        }
    } catch {
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
    let selectionStore = KeyboardSelectionStore(url: KeyphoreRuntimePaths.keyboardSelectionURL())
    let experimentalStore = ExperimentalKeyboardStore()
    lighting.experimentalStore = experimentalStore
    if let mode = arguments.dropFirst().first,
       ["--inspect-air75-v2", "--preview-air75-v2"].contains(mode) {
        var lightingAttempted = false
        do {
            try withExtendedLifetime(lease) {
                let state = try lighting.inspectAir75V2State()
                func output(_ fields: [String: Any]) throws {
                    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                }
                try output(["model": "Air75 V2", "stage": "before", "mainState": state])
                if mode == "--preview-air75-v2" {
                    let profile = LocalProfile.default
                    let steps: [(String, LightingBehavior)] = [
                        ("blue-breathing", .signal(profile.execution)),
                        ("orange-breathing", .signal(profile.attention)),
                        ("green-static", .signal(profile.completion)),
                        ("off", .off),
                    ]
                    for (name, behavior) in steps {
                        // Recheck the unified selector before every step, including model changes.
                        _ = try lighting.inspectAir75V2State()
                        lightingAttempted = true
                        let evidence = try lighting.applyAndVerify(behavior)
                        try output(["stage": name, "mainState": evidence.mainState,
                            "protocolReadbackSucceeded": evidence.protocolReadbackSucceeded,
                            "unmanagedZoneProtection": evidence.unmanagedZoneProtection.rawValue,
                            "visualConfirmation": "notRequested"])
                        if name != "off" { RunLoop.current.run(until: Date().addingTimeInterval(5)) }
                    }
                }
            }
            exit(0)
        } catch {
            // Never clean up by writing to a different model attached during the test.
            withExtendedLifetime(lease) {
                if lightingAttempted, (try? lighting.inspectAir75V2State()) != nil { try? lighting.apply(.off) }
            }
            FileHandle.standardError.write(Data("Air75 V2 inspection/preview failed: \(error)\n".utf8))
            exit(1)
        }
    }
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
        profileProvider: { model in
            guard let model else { throw KeyboardSelectionFailure.stateUnavailable }
            return try profileStore.load(for: model)
        },
        lighting: lighting,
        keyboardHealthStore: healthStore,
        previewStore: previewStore,
        signalOffAcknowledgement: SignalOffAcknowledgementStore(
            url: KeyphoreRuntimePaths.signalOffAcknowledgementURL()
        ),
        quitGate: QuitGateStore(url: KeyphoreRuntimePaths.quitGateURL()),
        ownershipStore: ownershipStore,
        selectionStore: selectionStore,
        selectionSnapshotStore: KeyboardSelectionSnapshotStore(url: KeyphoreRuntimePaths.keyboardSelectionSnapshotURL()),
        interruptionReconciler: CodexInterruptionReconciler()
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
            let permitsExperiment: Bool
            do {
                permitsExperiment = try selectionStore.load() == nil && ownershipStore.load().zones.isEmpty
                    && lighting.selectedModel == nil
            } catch { permitsExperiment = false }
            if permitsExperiment {
                do {
                    holdsExperimentalRuntime = try experiments.poll(
                        quitting: QuitGateStore(url: KeyphoreRuntimePaths.quitGateURL()).isActive
                    )
                } catch { holdsExperimentalRuntime = true }
            } else { holdsExperimentalRuntime = false }
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
