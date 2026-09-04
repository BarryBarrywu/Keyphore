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
        anotherModel.productID = 0x1029
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

    func testSelectsBothAir75FirmwareNamesAndRejectsMixedSupportedDevices() throws {
        for name in ["NuPhy Air75 V3", "Air75 V3"] {
            var device = air65()
            device.productID = 0x1028
            device.product = name
            XCTAssertEqual(try Air65DeviceSelector.select(from: [device]), device)
            XCTAssertThrowsError(try Air65DeviceSelector.select(from: [device, air65()])) {
                XCTAssertEqual($0 as? Air65DeviceSelectionError, .ambiguous)
            }
            for mutation in 0..<4 {
                var unsupported = device
                switch mutation {
                case 0: unsupported.bus = .bluetooth
                case 1: unsupported.interfaceNumber = 1
                case 2: unsupported.usage = 6
                default: unsupported.productID = 0x1029
                }
                XCTAssertThrowsError(try Air65DeviceSelector.select(from: [unsupported]))
            }
        }
    }

    func testKick75ReferenceIdentityIsRecognitionOnly() throws {
        var kick = air65()
        kick.productID = 0x1026
        kick.product = "Kick75"
        XCTAssertEqual(UnverifiedKeyboardInterface(kick).model, .kick75IO)
        XCTAssertThrowsError(try Air65DeviceSelector.select(from: [kick])) {
            XCTAssertEqual($0 as? Air65DeviceSelectionError, .unverified([UnverifiedKeyboardInterface(kick)]))
        }
        XCTAssertEqual(try Air65DeviceSelector.select(from: [kick, air65()]), air65())
        kick.vendorID = 0xffff
        XCTAssertNil(UnverifiedKeyboardInterface(kick).model)
        kick.vendorID = 0x19f5
        kick.productID = 0xffff
        XCTAssertNil(UnverifiedKeyboardInterface(kick).model)
        XCTAssertThrowsError(try Air65DeviceSelector.select(from: [kick])) {
            XCTAssertEqual($0 as? Air65DeviceSelectionError, .notFound)
        }
    }

    func testCatalogCoversCandidateVariantsWithDistinctIdentitiesAndLayouts() {
        let models = CandidateKeyboardModel.allCases
        XCTAssertEqual(models.count, 33)
        XCTAssertEqual(Set(models.map { $0.definition.productID }).count, models.count)
        XCTAssertEqual(CandidateKeyboardCatalog.definitions.count, models.count)
        for model in models {
            let definition = model.definition
            XCTAssertGreaterThan(definition.keys.count, 50, model.rawValue)
            XCTAssertGreaterThan(definition.aspectRatio, 1.5, model.rawValue)
            XCTAssertLessThan(definition.aspectRatio, 4, model.rawValue)
            XCTAssertTrue(definition.keys.allSatisfy {
                $0.x >= 0 && $0.y >= 0 && $0.width > 0 && $0.height > 0
            }, model.rawValue)
            var descriptor = air65()
            descriptor.productID = definition.productID
            descriptor.product = "Firmware product name"
            XCTAssertEqual(UnverifiedKeyboardInterface(descriptor).model, model)
            XCTAssertThrowsError(try Air65DeviceSelector.select(from: [descriptor])) {
                XCTAssertEqual($0 as? Air65DeviceSelectionError, .unverified([UnverifiedKeyboardInterface(descriptor)]))
            }
        }
        XCTAssertEqual(CandidateKeyboardModel.air100V3.definition.productID, 0x102d)
        XCTAssertEqual(CandidateKeyboardModel.air100V3ISO.definition.productID, 0x1039)
        XCTAssertEqual(CandidateKeyboardModel.air100V3JIS.definition.productID, 0x103f)
        XCTAssertNotEqual(CandidateKeyboardModel.air100V3ISO.definition.keys,
                          CandidateKeyboardModel.air100V3JIS.definition.keys)
        for productID: UInt16 in [0x0720, 0x0721, 0x072d, 0x0739, 0x073f, 0x2620, 0x8f01, 0xffff] {
            XCTAssertNil(CandidateKeyboardModel.identify(vendorID: 0x19f5, productID: productID, product: "Air100 V3"))
        }
        XCTAssertNil(CandidateKeyboardModel.identify(vendorID: 0xffff, productID: 0x102d, product: "Air100 V3"))
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
