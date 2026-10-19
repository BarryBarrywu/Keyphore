import Foundation
import IOKit.hid

public final class SystemAir65TransportDiscovery: Air65TransportDiscovering {
    private var manager: IOHIDManager
    private var devicesByID: [String: IOHIDDevice] = [:]
    private var reportStatesByID: [String: SystemAir65ReportState] = [:]

    public init() {
        manager = Self.makeManager()
    }

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func discover() throws -> [HIDDeviceDescriptor] {
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw SystemAir65HIDError.managerOpenFailed(result)
        }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        devicesByID.removeAll(keepingCapacity: true)
        return devices.compactMap { device in
            guard
                let vendorID = numberProperty(device, kIOHIDVendorIDKey),
                let productID = numberProperty(device, kIOHIDProductIDKey),
                let interfaceNumber = Self.resolvedInterfaceNumber(
                    hidInterfaceID: numberProperty(device, kIOHIDInterfaceIDKey),
                    usbInterfaceNumber: usbInterfaceNumber(device)
                ),
                let usagePage = numberProperty(device, kIOHIDPrimaryUsagePageKey),
                let usage = numberProperty(device, kIOHIDPrimaryUsageKey)
            else {
                return nil
            }
            let id = registryID(device)
            devicesByID[id] = device
            return HIDDeviceDescriptor(
                id: id,
                vendorID: UInt16(truncatingIfNeeded: vendorID),
                productID: UInt16(truncatingIfNeeded: productID),
                product: stringProperty(device, kIOHIDProductKey) ?? "",
                bus: bus(stringProperty(device, kIOHIDTransportKey)),
                interfaceNumber: interfaceNumber,
                usagePage: UInt16(truncatingIfNeeded: usagePage),
                usage: UInt16(truncatingIfNeeded: usage),
                usbRevision: numberProperty(device, kIOHIDVersionNumberKey)
            )
        }
    }

    static func resolvedInterfaceNumber(
        hidInterfaceID: Int?,
        usbInterfaceNumber: Int?
    ) -> Int? {
        usbInterfaceNumber ?? hidInterfaceID
    }

    public func open(_ descriptor: HIDDeviceDescriptor) throws -> any Air65ReportTransport {
        guard let device = devicesByID[descriptor.id] else {
            throw SystemAir65HIDError.deviceDisappeared
        }
        let format: HIDReportFormat = SupportedKeyboardModel.identify(descriptor) == .air75V2 ? .via : .nuphy
        if format == .via {
            let reportDescriptor = (IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data).map(Array.init) ?? []
            try VIAProtocol.validateDescriptor(reportDescriptor,
                inputSize: numberProperty(device, kIOHIDMaxInputReportSizeKey),
                outputSize: numberProperty(device, kIOHIDMaxOutputReportSizeKey))
        }
        let state = reportStatesByID[descriptor.id] ?? SystemAir65ReportState(format: format)
        reportStatesByID[descriptor.id] = state
        return try SystemAir65ReportTransport(device: device, state: state)
    }

    public func resetDiscoveryState() {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        devicesByID.removeAll(keepingCapacity: true)
        reportStatesByID.removeAll(keepingCapacity: true)
        manager = Self.makeManager()
    }

    private static func makeManager() -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Unrelated HID services can fail to open even when no NuPhy keyboard is attached.
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Int(Air65DeviceSelector.vendorID)] as CFDictionary)
        return manager
    }

    private func numberProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private func usbInterfaceNumber(_ device: IOHIDDevice) -> Int? {
        var parent: io_registry_entry_t = 0
        let result = IORegistryEntryGetParentEntry(
            IOHIDDeviceGetService(device),
            kIOServicePlane,
            &parent
        )
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return (
            IORegistryEntryCreateCFProperty(
                parent,
                "bInterfaceNumber" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? NSNumber
        )?.intValue
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private func registryID(_ device: IOHIDDevice) -> String {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return String(id)
    }

    private func bus(_ transport: String?) -> HIDBus {
        switch transport?.lowercased() {
        case "usb": .usb
        case "bluetooth", "bluetooth low energy": .bluetooth
        default: .other
        }
    }
}

public enum SystemAir65HIDError: Error, Sendable {
    case managerOpenFailed(IOReturn)
    case deviceDisappeared
    case deviceOpenFailed(IOReturn)
    case reportWriteFailed(IOReturn)
    case reportReadFailed(IOReturn)
    case unexpectedReportLength(Int)
}

enum HIDReportFormat {
    case nuphy, via

    var bufferSize: Int { self == .via ? 32 : 65 }

    func output(_ report: [UInt8]) throws -> [UInt8] {
        if self == .nuphy { return try NuPhyProtocol.parseReport(report) }
        guard report.count == 32 else { throw SystemAir65HIDError.unexpectedReportLength(report.count) }
        return report
    }

    func input(_ report: [UInt8], reportID: UInt32) throws -> [UInt8] {
        if self == .via {
            guard reportID == 0, report.count == 32 else { throw VIAProtocolError.invalidReport }
            return report
        }
        if report.count == 64 { return report }
        if report.count == 65 { return Array(report.dropFirst()) }
        throw SystemAir65HIDError.unexpectedReportLength(report.count)
    }
}

private final class SystemAir65ReportTransport: Air65ReportTransport {
    private let device: IOHIDDevice
    private let state: SystemAir65ReportState

    init(device: IOHIDDevice, state: SystemAir65ReportState) throws {
        self.device = device
        self.state = state
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw SystemAir65HIDError.deviceOpenFailed(result)
        }
        IOHIDDeviceRegisterInputReportCallback(
            device,
            state.inputBuffer,
            state.format.bufferSize,
            { context, result, _, _, reportID, report, reportLength in
                guard let context else { return }
                let state = Unmanaged<SystemAir65ReportState>
                    .fromOpaque(context).takeUnretainedValue()
                state.accept(result: result, report: report, length: reportLength, reportID: reportID)
            },
            Unmanaged.passUnretained(state).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        state.drainQueuedReports()
    }

    deinit {
        IOHIDDeviceRegisterInputReportCallback(
            device,
            state.inputBuffer,
            state.format.bufferSize,
            nil,
            nil
        )
        IOHIDDeviceUnscheduleFromRunLoop(
            device,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func send(_ report: [UInt8]) throws {
        let parsed = try state.format.output(report)
        let result = parsed.withUnsafeBytes { bytes in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                0,
                bytes.bindMemory(to: UInt8.self).baseAddress!,
                parsed.count
            )
        }
        guard result == kIOReturnSuccess else {
            throw SystemAir65HIDError.reportWriteFailed(result)
        }
    }

    func receive(timeout: TimeInterval) throws -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let report = state.nextReport() {
                return try report.get()
            }
            RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.01))
            )
        }
        return nil
    }
}

private final class SystemAir65ReportState {
    let format: HIDReportFormat
    let inputBuffer: UnsafeMutablePointer<UInt8>
    private var reports: [Result<[UInt8], Error>] = []
    private let lock = NSLock()

    init(format: HIDReportFormat) {
        self.format = format
        inputBuffer = .allocate(capacity: format.bufferSize)
        inputBuffer.initialize(repeating: 0, count: format.bufferSize)
    }

    deinit {
        inputBuffer.deinitialize(count: format.bufferSize)
        inputBuffer.deallocate()
    }

    func accept(result: IOReturn, report: UnsafeMutablePointer<UInt8>, length: CFIndex, reportID: UInt32) {
        let received: Result<[UInt8], Error>
        if result != kIOReturnSuccess {
            received = .failure(SystemAir65HIDError.reportReadFailed(result))
        } else if length < 0 || length > format.bufferSize {
            received = .failure(SystemAir65HIDError.unexpectedReportLength(length))
        } else {
            received = Result { try format.input(Array(UnsafeBufferPointer(start: report, count: length)), reportID: reportID) }
        }
        lock.lock()
        reports.append(received)
        lock.unlock()
    }

    func nextReport() -> Result<[UInt8], Error>? {
        lock.lock()
        defer { lock.unlock() }
        return reports.isEmpty ? nil : reports.removeFirst()
    }

    func drainQueuedReports() {
        lock.lock()
        reports.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
