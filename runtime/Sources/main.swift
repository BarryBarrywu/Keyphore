import Foundation
import KeyphoreCore

private let arguments = CommandLine.arguments.dropFirst()
private let store = DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL())

switch arguments.first {
case "hook":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 1_048_576 else {
        exit(1)
    }
    guard (try? ProductionHookHandler(store: store).handle(input)) != nil else {
        exit(1)
    }
case "companion":
    let lighting = RuntimeLightingBoundary()
    let companion = KeyphoreCompanion(store: store, profile: .default, lighting: lighting)
    while true {
        try? companion.sync()
        Thread.sleep(forTimeInterval: 0.1)
    }
default:
    exit(64)
}

private final class RuntimeLightingBoundary: CompanionLightingApplying {
    private var currentBehavior: LightingBehavior = .off

    func apply(_ behavior: LightingBehavior) throws {
        currentBehavior = behavior
    }
}
