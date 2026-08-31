import KeyphoreCore
import XCTest

final class Air65DeviceSelectionTests: XCTestCase {
    func testSelectsOnlyTheVerifiedWiredControlInterface() throws {
        var keyboardInterface = air65()
        keyboardInterface.id = "ordinary-keyboard"
        keyboardInterface.usage = 0x0006

        let selected = try Air65DeviceSelector.select(from: [keyboardInterface, air65()])

        XCTAssertEqual(selected.id, "air65-control")
    }

    func testRejectsMissingUnsupportedAndAmbiguousDevices() {
        var anotherModel = air65()
        anotherModel.productID = 0x1028
        anotherModel.product = "Air75 V3"

        var bluetooth = air65()
        bluetooth.bus = .bluetooth

        var receiver = air65()
        receiver.bus = .other

        var wrongInterface = air65()
        wrongInterface.interfaceNumber = 1

        var typingInterface = air65()
        typingInterface.usage = 0x0006

        XCTAssertThrowsError(try Air65DeviceSelector.select(from: [])) {
            XCTAssertEqual($0 as? Air65DeviceSelectionError, .notFound)
        }
        for descriptor in [anotherModel, bluetooth, receiver, wrongInterface, typingInterface] {
            XCTAssertThrowsError(try Air65DeviceSelector.select(from: [descriptor]))
        }
        XCTAssertThrowsError(try Air65DeviceSelector.select(from: [air65(), air65()])) {
            XCTAssertEqual($0 as? Air65DeviceSelectionError, .ambiguous)
        }
    }

    private func air65() -> HIDDeviceDescriptor {
        HIDDeviceDescriptor(
            id: "air65-control",
            vendorID: 0x19f5,
            productID: 0x102b,
            product: "Air65 V3",
            bus: .usb,
            interfaceNumber: 3,
            usagePage: 0x0001,
            usage: 0x0000
        )
    }
}
