import AppKit
import KeyphoreCore
import SwiftUI
import XCTest

@MainActor
final class PopoverLayoutTests: XCTestCase {
    func testDisconnectedKeyboardUsesGenericPresentation() {
        let state = KeyphoreAppState(environment: ["KEYPHORE_ACCEPTANCE_FIXTURE": "configured"])
        let popover = KeyphorePopover(state: state)

        XCTAssertTrue(popover.usesGenericKeyboardPresentation)
    }

    func testMenuBarPanelRetainsKeyboardSpaceUnderCompressedHeightProposal() {
        for fixture in ["ready-execution", "ready-attention", "ready-completion", "configured", "ready-off"] {
            let state = KeyphoreAppState(environment: ["KEYPHORE_ACCEPTANCE_FIXTURE": fixture])
            let hosting = NSHostingController(rootView: KeyphorePopover(state: state))

            let size = hosting.sizeThatFits(in: NSSize(width: 392, height: 0))

            XCTAssertEqual(size.width, 392, accuracy: 1)
            XCTAssertGreaterThanOrEqual(size.height, 350, "The approved panel must reserve its 344 × 132 keyboard even during intrinsic sizing: \(fixture)")
            XCTAssertLessThanOrEqual(size.height, 370, "The approved status-first panel has no management footer: \(fixture)")
        }
    }
}
