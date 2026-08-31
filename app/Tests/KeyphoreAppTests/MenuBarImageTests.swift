import XCTest
import KeyphoreCore

final class MenuBarImageTests: XCTestCase {
    func testEverySignalUsesSystemAdaptiveMenuBarRendering() {
        for signal in [
            AggregateSignal.signalOff,
            .execution,
            .attention,
            .completion,
        ] {
            XCTAssertTrue(
                signal.presentation(in: .default).menuBarImage.isTemplate,
                "\(signal) must remain visible on every menu bar background"
            )
        }
    }
}
