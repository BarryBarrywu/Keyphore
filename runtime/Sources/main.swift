import Foundation
import KeyphoreCore

private let arguments = CommandLine.arguments.dropFirst()
private let store = DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL())
private let profile = LocalProfile.default

switch arguments.first {
case "hook":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 1_048_576 else {
        exit(1)
    }
    guard (try? ProductionHookHandler(store: store, profile: profile).handle(input)) != nil else {
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
    let companion = KeyphoreCompanion(
        store: store,
        profile: profile,
        lighting: lighting,
        keyboardHealthStore: healthStore
    )
    let recovery = CompanionRecoveryController(companion: companion)
    let powerEvents = SystemPowerEventMonitor { event in
        try? recovery.handle(event)
    }
    var lastHealthCheck = ContinuousClock.now
    while true {
        try? recovery.poll()
        if lastHealthCheck.duration(to: .now) >= .seconds(1) {
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
