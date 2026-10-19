#!/usr/bin/env swift
// Read-only Air75 V2 diagnostic. This is not a physical lighting acceptance test.
import Darwin
import Foundation
import IOKit.hid

private struct InspectionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private enum Query: String, CaseIterable {
    case version, brightness, effect, speed, color

    var prefix: [UInt8] {
        switch self {
        case .version: [0x01]
        case .brightness: [0x08, 0x03, 0x01]
        case .effect: [0x08, 0x03, 0x02]
        case .speed: [0x08, 0x03, 0x03]
        case .color: [0x08, 0x03, 0x04]
        }
    }

    var request: [UInt8] { prefix + Array(repeating: 0, count: 32 - prefix.count) }

    func parse(_ response: [UInt8]) throws -> [String: Int] {
        guard response.count == 32 else { throw InspectionError("Expected a 32-byte response") }
        guard response[0] != 0xff else { throw InspectionError("VIA command is unhandled") }
        guard response.starts(with: prefix) else { throw InspectionError("Response command/channel/value mismatch") }
        switch self {
        case .version:
            let version = Int(response[1]) << 8 | Int(response[2])
            guard version == 12 else { throw InspectionError("Unsupported VIA protocol version: \(version)") }
            return ["protocolVersion": version]
        case .brightness: return ["brightness": Int(response[3])]
        case .effect: return ["effect": Int(response[3])]
        case .speed: return ["speed": Int(response[3])]
        case .color: return ["hue": Int(response[3]), "saturation": Int(response[4])]
        }
    }
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

private struct Exchange: Encodable {
    let query: String
    let request: String
    var response: String?
    var values: [String: Int]?
}

private struct Report: Encodable {
    var device: [String: String] = [:]
    var exchanges: [Exchange] = []
    var error: String?
}

private final class InputState {
    var response: [UInt8]?
    var error: InspectionError?
}

private func inspect(_ report: inout Report) throws {
    let lockURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Keyphore/companion.lock")
    let lockFD = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lockFD >= 0 else { throw InspectionError("Cannot open Companion lock") }
    defer { close(lockFD) }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        throw InspectionError("Companion lock is owned; quit Keyphore through the App first")
    }
    defer { flock(lockFD, LOCK_UN) }

    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [
        kIOHIDVendorIDKey: 0x19f5,
        kIOHIDProductIDKey: 0x3246,
        kIOHIDPrimaryUsagePageKey: 0xff60,
        kIOHIDPrimaryUsageKey: 0x61,
        kIOHIDTransportKey: "USB",
        kIOHIDProductKey: "NuPhy Air75 V2",
    ] as CFDictionary)
    let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard managerResult == kIOReturnSuccess else { throw InspectionError("HID manager open failed: \(managerResult)") }
    defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    guard devices.count == 1, let device = devices.first else {
        throw InspectionError("Expected exactly one matching wired Air75 V2 RAW HID interface; found \(devices.count)")
    }
    func number(_ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
    func string(_ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
    guard number(kIOHIDVendorIDKey) == 0x19f5, number(kIOHIDProductIDKey) == 0x3246,
          number(kIOHIDPrimaryUsagePageKey) == 0xff60, number(kIOHIDPrimaryUsageKey) == 0x61,
          string(kIOHIDTransportKey) == "USB", string(kIOHIDProductKey) == "NuPhy Air75 V2" else {
        throw InspectionError("Device identity mismatch")
    }
    let descriptor = (IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data).map(Array.init) ?? []
    // The observed V2 descriptor has no report ID and declares 32-byte input/output.
    let expectedDescriptor: [UInt8] = [
        0x06, 0x60, 0xff, 0x09, 0x61, 0xa1, 0x01, 0x09, 0x62, 0x15, 0x00,
        0x26, 0xff, 0x00, 0x95, 0x20, 0x75, 0x08, 0x81, 0x02, 0x09, 0x63,
        0x15, 0x00, 0x26, 0xff, 0x00, 0x95, 0x20, 0x75, 0x08, 0x91, 0x02, 0xc0,
    ]
    report.device = [
        "vendorID": "19f5", "productID": "3246", "product": "NuPhy Air75 V2",
        "transport": "USB", "usagePage": "ff60", "usage": "0061",
        "usbVersionNumber": number(kIOHIDVersionNumberKey).map(String.init) ?? "unavailable",
        "maxInputReportSize": number(kIOHIDMaxInputReportSizeKey).map(String.init) ?? "unavailable",
        "maxOutputReportSize": number(kIOHIDMaxOutputReportSizeKey).map(String.init) ?? "unavailable",
        "reportDescriptor": hex(descriptor),
    ]
    guard number(kIOHIDMaxInputReportSizeKey) == 32, number(kIOHIDMaxOutputReportSizeKey) == 32,
          descriptor == expectedDescriptor else {
        throw InspectionError("Unexpected RAW HID report sizes or descriptor; no query sent")
    }
    let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openResult == kIOReturnSuccess else { throw InspectionError("HID device open failed: \(openResult)") }
    defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
    let state = InputState()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)
    buffer.initialize(repeating: 0, count: 32)
    defer { buffer.deinitialize(count: 32); buffer.deallocate() }
    IOHIDDeviceRegisterInputReportCallback(device, buffer, 32, { context, result, _, type, reportID, bytes, length in
        guard let context else { return }
        let state = Unmanaged<InputState>.fromOpaque(context).takeUnretainedValue()
        guard state.response == nil, state.error == nil else { return }
        state.response = Array(UnsafeBufferPointer(start: bytes, count: max(0, min(32, length))))
        if result != kIOReturnSuccess || type != kIOHIDReportTypeInput || reportID != 0 || length != 32 {
            state.error = InspectionError("Invalid HID response: result=\(result), reportID=\(reportID), length=\(length)")
        }
    }, Unmanaged.passUnretained(state).toOpaque())
    let runLoop = CFRunLoopGetCurrent()!
    IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
    defer {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 32, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        withExtendedLifetime(state) {}
    }
    for query in Query.allCases {
        state.response = nil
        state.error = nil
        report.exchanges.append(Exchange(query: query.rawValue, request: hex(query.request)))
        let sent = query.request.withUnsafeBytes { bytes in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0,
                                 bytes.bindMemory(to: UInt8.self).baseAddress!, bytes.count)
        }
        guard sent == kIOReturnSuccess else { throw InspectionError("Query send failed: \(sent)") }
        let deadline = ContinuousClock.now + .seconds(1)
        while state.response == nil, state.error == nil, ContinuousClock.now < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        report.exchanges[report.exchanges.count - 1].response = state.response.map(hex)
        if let error = state.error { throw error }
        guard let response = state.response else { throw InspectionError("Query timed out: \(query.rawValue)") }
        report.exchanges[report.exchanges.count - 1].values = try query.parse(response)
    }
}

private func selfTest() throws {
    func check(_ condition: Bool) throws {
        guard condition else { throw InspectionError("Self-test failed") }
    }
    func rejects(_ query: Query, _ response: [UInt8]) throws {
        do { _ = try query.parse(response) } catch { return }
        throw InspectionError("Invalid response accepted")
    }
    try check(Query.allCases.map(\.prefix) == [[1], [8, 3, 1], [8, 3, 2], [8, 3, 3], [8, 3, 4]])
    for query in Query.allCases {
        try check(query.request.count == 32 && query.request.dropFirst(query.prefix.count).allSatisfy { $0 == 0 })
        var response = query.request
        if query == .version { response[2] = 12 } else { response[3] = 42; response[4] = 180 }
        let values = try query.parse(response)
        try check(!values.isEmpty)
        if query == .color { try check(values == ["hue": 42, "saturation": 180]) }
        try rejects(query, Array(response.dropLast()))
        try rejects(query, response + [0])
        response[0] = 0xff
        try rejects(query, response)
        response[0] = 7
        try rejects(query, response)
        if query != .version {
            response = query.request; response[1] = 4
            try rejects(query, response)
            response = query.request; response[2] = 99
            try rejects(query, response)
        }
    }
    try rejects(.version, Query.version.request)
    var unknown = Query.version.request; unknown[2] = 13
    try rejects(.version, unknown)
}

private var report = Report()
do {
    switch Array(CommandLine.arguments.dropFirst()) {
    case ["--self-test"]:
        try selfTest()
        print("{\"selfTest\":\"passed\",\"hardwareAccess\":false}")
        exit(0)
    case []: try inspect(&report)
    default: throw InspectionError("Usage: keyphore-via-inspect [--self-test]")
    }
} catch {
    report.error = String(describing: error)
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(report))
print()
exit(report.error == nil ? 0 : 1)
