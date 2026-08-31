import XCTest
@testable import KeyphoreCore

final class SystemAir65HIDTests: XCTestCase {
    func testUsesUSBParentInterfaceNumberWhenHIDInterfaceIDIsMissing() {
        XCTAssertEqual(
            SystemAir65TransportDiscovery.resolvedInterfaceNumber(
                hidInterfaceID: nil,
                usbInterfaceNumber: 3
            ),
            3
        )
    }

    func testFallsBackToHIDInterfaceIDWithoutAUSBParent() {
        XCTAssertEqual(
            SystemAir65TransportDiscovery.resolvedInterfaceNumber(
                hidInterfaceID: 3,
                usbInterfaceNumber: nil
            ),
            3
        )
    }
}
