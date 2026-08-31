import Dispatch
import Foundation
import KeyphoreCore

private let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case "hook":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 1_048_576 else {
        exit(1)
    }
    guard (try? PrivacyAllowedHookRecord(
        jsonData: input,
        receivedAt: ISO8601DateFormatter().string(from: Date())
    )) != nil else {
        exit(1)
    }
case "companion":
    dispatchMain()
default:
    exit(64)
}
