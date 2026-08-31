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
    let healthStore = KeyboardHealthStore(url: KeyphoreRuntimePaths.keyboardHealthURL())
    let lighting = NuPhyIOAdapter(discovery: SystemAir65TransportDiscovery())
    let companion = KeyphoreCompanion(
        store: store,
        profile: profile,
        lighting: lighting,
        keyboardHealthStore: healthStore
    )
    var lastHealthCheck = ContinuousClock.now
    while true {
        try? companion.sync()
        if lastHealthCheck.duration(to: .now) >= .seconds(1) {
            try? companion.healthCheck()
            lastHealthCheck = .now
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
default:
    exit(64)
}
