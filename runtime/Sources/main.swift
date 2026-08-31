import Dispatch
import Foundation

private let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case "hook":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 1_048_576 else {
        exit(1)
    }
    guard (try? JSONSerialization.jsonObject(with: input)) != nil else {
        exit(1)
    }
case "companion":
    dispatchMain()
default:
    exit(64)
}
