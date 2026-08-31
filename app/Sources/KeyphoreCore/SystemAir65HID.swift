import Foundation
import IOKit.hid

public final class SystemAir65TransportDiscovery: Air65TransportDiscovering {
    private let manager: IOHIDManager
    private var devicesByID: [String: IOHIDDevice] = [:]

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
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
                let interfaceNumber = numberProperty(device, kIOHIDInterfaceIDKey),
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
                usage: UInt16(truncatingIfNeeded: usage)
            )
        }
    }

    public func open(_ descriptor: HIDDeviceDescriptor) throws -> any Air65ReportTransport {
        guard let device = devicesByID[descriptor.id] else {
            throw SystemAir65HIDError.deviceDisappeared
        }
        return try SystemAir65ReportTransport(device: device)
    }

    private func numberProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
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

private final class SystemAir65ReportTransport: Air65ReportTransport {
    private let device: IOHIDDevice
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65)
    private var reports: [Result<[UInt8], Error>] = []
    private let lock = NSLock()

    init(device: IOHIDDevice) throws {
        self.device = device
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            inputBuffer.deallocate()
            throw SystemAir65HIDError.deviceOpenFailed(result)
        }
        inputBuffer.initialize(repeating: 0, count: 65)
        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputBuffer,
            65,
            { context, result, _, _, _, report, reportLength in
                guard let context else { return }
                let owner = Unmanaged<SystemAir65ReportTransport>
                    .fromOpaque(context).takeUnretainedValue()
                owner.accept(result: result, report: report, length: reportLength)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        drainQueuedReports()
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(
            device,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        inputBuffer.deinitialize(count: 65)
        inputBuffer.deallocate()
    }

    func send(_ report: [UInt8]) throws {
        let parsed = try NuPhyProtocol.parseReport(report)
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
            if let report = nextReport() {
                return try report.get()
            }
            RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.01))
            )
        }
        return nil
    }

    private func accept(result: IOReturn, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let received: Result<[UInt8], Error>
        if result != kIOReturnSuccess {
            received = .failure(SystemAir65HIDError.reportReadFailed(result))
        } else if length == 64 {
            received = .success(Array(UnsafeBufferPointer(start: report, count: 64)))
        } else if length == 65 {
            received = .success(Array(UnsafeBufferPointer(start: report + 1, count: 64)))
        } else {
            received = .failure(SystemAir65HIDError.unexpectedReportLength(length))
        }
        lock.lock()
        reports.append(received)
        lock.unlock()
    }

    private func nextReport() -> Result<[UInt8], Error>? {
        lock.lock()
        defer { lock.unlock() }
        return reports.isEmpty ? nil : reports.removeFirst()
    }

    private func drainQueuedReports() {
        lock.lock()
        reports.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
