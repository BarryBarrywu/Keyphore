public enum HIDBus: Equatable, Sendable {
    case usb
    case bluetooth
    case other
}

public struct HIDDeviceDescriptor: Equatable, Sendable {
    public var id: String
    public var vendorID: UInt16
    public var productID: UInt16
    public var product: String
    public var bus: HIDBus
    public var interfaceNumber: Int
    public var usagePage: UInt16
    public var usage: UInt16

    public init(
        id: String,
        vendorID: UInt16,
        productID: UInt16,
        product: String,
        bus: HIDBus,
        interfaceNumber: Int,
        usagePage: UInt16,
        usage: UInt16
    ) {
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.product = product
        self.bus = bus
        self.interfaceNumber = interfaceNumber
        self.usagePage = usagePage
        self.usage = usage
    }
}

public enum Air65DeviceSelectionError: Error, Equatable, Sendable {
    case notFound
    case unsupported
    case ambiguous
}

public enum Air65DeviceSelector {
    public static let vendorID: UInt16 = 0x19f5
    public static let productID: UInt16 = 0x102b

    public static func select(from devices: [HIDDeviceDescriptor]) throws -> HIDDeviceDescriptor {
        let matchingModel = devices.filter {
            $0.vendorID == vendorID && $0.productID == productID
        }
        guard !matchingModel.isEmpty else {
            throw Air65DeviceSelectionError.notFound
        }

        let supported = matchingModel.filter {
            $0.product == "Air65 V3"
                && $0.bus == .usb
                && $0.interfaceNumber == 3
                && $0.usagePage == 0x0001
                && $0.usage == 0x0000
        }
        guard !supported.isEmpty else {
            throw Air65DeviceSelectionError.unsupported
        }
        guard supported.count == 1 else {
            throw Air65DeviceSelectionError.ambiguous
        }
        return supported[0]
    }
}
