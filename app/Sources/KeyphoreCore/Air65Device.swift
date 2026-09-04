import Foundation

public enum HIDBus: String, Codable, Equatable, Sendable {
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

public enum CandidateKeyboardModel: String, CaseIterable, Sendable {
    case kick75HighIO = "Kick75 IO HP"
    case field75HE = "Field75 HE"
    case field75HEV2 = "Field75 HE V2"
    case air60HE = "Air60 HE"
    case halo65HE = "Halo65 HE"
    case kick75IO = "Kick75 IO"
    case air75HE = "Air75 HE"
    case bH65HE = "BH65 HE"
    case air75V3 = "Air75 V3"
    case air75V3ISO = "Air75 V3 ISO"
    case air75V3JIS = "Air75 V3 JIS"
    case halo65Lite = "Halo65 V2 IO"
    case halo75Lite = "Halo75 V2 IO"
    case halo96Lite = "Halo96 V2 IO"
    case node75 = "Node75 LP ANSI"
    case node75High = "Node75 HP ANSI"
    case air65V3ISO = "Air65 V3 ISO"
    case air65V3JIS = "Air65 V3 JIS"
    case air100V3 = "Air100 V3 ANSI"
    case air100V3ISO = "Air100 V3 ISO"
    case air100V3JIS = "Air100 V3 JIS"
    case halo75V2ISO = "Halo75 V2 IO ISO"
    case halo96V2ISO = "Halo96 V2 IO ISO"
    case node75HighISO = "Node75 HP ISO"
    case node75HighJIS = "Node75 HP JIS"
    case node75ISO = "Node75 LP ISO"
    case node75JIS = "Node75 LP JIS"
    case node100 = "Node100 LP ANSI"
    case node100High = "Node100 HP ANSI"
    case node100ISO = "Node100 LP ISO"
    case node100JIS = "Node100 LP JIS"
    case node100HighISO = "Node100 HP ISO"
    case node100HighJIS = "Node100 HP JIS"

    public var definition: CandidateKeyboardDefinition {
        CandidateKeyboardCatalog.definitions.first { $0.name == rawValue }!
    }

    public static func identify(vendorID: UInt16, productID: UInt16, product: String) -> Self? {
        guard vendorID == 0x19f5 else { return nil }
        return CandidateKeyboardCatalog.modelsByProductID[productID]
    }
}

public struct UnverifiedKeyboardInterface: Codable, Equatable, Sendable {
    public let product: String
    public let vendorID: UInt16
    public let productID: UInt16
    public let bus: HIDBus
    public let interfaceNumber: Int
    public let usagePage: UInt16
    public let usage: UInt16

    public init(_ device: HIDDeviceDescriptor) {
        product = device.product
        vendorID = device.vendorID
        productID = device.productID
        bus = device.bus
        interfaceNumber = device.interfaceNumber
        usagePage = device.usagePage
        usage = device.usage
    }

    public var model: CandidateKeyboardModel? {
        CandidateKeyboardModel.identify(vendorID: vendorID, productID: productID, product: product)
    }

    public var diagnosticDescription: String {
        String(format: "%@ · %04x:%04x · %@ · interface %d · %04x:%04x",
               product, Int(vendorID), Int(productID), bus.rawValue,
               interfaceNumber, Int(usagePage), Int(usage))
    }
}

public enum Air65DeviceSelectionError: Error, Equatable, Sendable {
    case notFound
    case unverified([UnverifiedKeyboardInterface])
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
            let candidates = devices.filter {
                CandidateKeyboardModel.identify(vendorID: $0.vendorID, productID: $0.productID, product: $0.product) != nil
            }.map(UnverifiedKeyboardInterface.init).sorted {
                $0.diagnosticDescription < $1.diagnosticDescription
            }
            if !candidates.isEmpty {
                throw Air65DeviceSelectionError.unverified(candidates)
            }
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
