public struct NuPhySessionKey: Equatable, Sendable {
    public let value: UInt8

    public init(_ value: UInt8) {
        self.value = value
    }
}

public enum NuPhyProtocolError: Error, Equatable, Sendable {
    case invalidReportLength
    case payloadTooLarge
    case invalidDirection
    case commandMismatch
    case checksumMismatch
    case sessionMismatch
    case responseLengthMismatch
    case responseAddressMismatch
    case responseHandleMismatch
}

public struct NuPhyRequest: Equatable, Sendable {
    fileprivate enum Command: UInt8, Sendable {
        case read = 0xd5
        case write = 0xd6
    }

    fileprivate let command: Command
    fileprivate let address: UInt16
    fileprivate let responseLength: UInt8
    fileprivate let payload: [UInt8]

    public static func write(address: UInt16, payload: [UInt8]) throws -> NuPhyRequest {
        guard payload.count <= NuPhyProtocol.payloadLength else {
            throw NuPhyProtocolError.payloadTooLarge
        }
        return NuPhyRequest(
            command: .write,
            address: address,
            responseLength: UInt8(payload.count),
            payload: payload
        )
    }

    public static func read(address: UInt16, length: UInt8) throws -> NuPhyRequest {
        guard Int(length) <= NuPhyProtocol.payloadLength else {
            throw NuPhyProtocolError.payloadTooLarge
        }
        return NuPhyRequest(
            command: .read,
            address: address,
            responseLength: length,
            payload: []
        )
    }

    public func encoded(using key: NuPhySessionKey) -> [UInt8] {
        var report = Array(repeating: UInt8(0), count: NuPhyProtocol.reportLength)
        report[0] = NuPhyProtocol.hostDirection
        report[1] = command.rawValue
        report[4] = responseLength ^ key.value
        report[5] = UInt8(truncatingIfNeeded: address) ^ key.value
        report[6] = UInt8(truncatingIfNeeded: address >> 8) ^ key.value
        report[7] = key.value
        for (index, byte) in payload.enumerated() {
            report[index + 8] = byte ^ key.value
        }
        report[3] = NuPhyProtocol.checksum(report)
        return report
    }

    public func isResponseCandidate(_ response: [UInt8], key: NuPhySessionKey) -> Bool {
        (try? NuPhyProtocol.validate(response, for: self, key: key)) != nil
    }
}

public enum NuPhyProtocol {
    public static let reportLength = 64
    public static let payloadLength = 56
    fileprivate static let hostDirection: UInt8 = 0x55
    private static let deviceDirection: UInt8 = 0xaa
    private static let temporarySessionCommand: UInt8 = 0xee

    public static func parseReport(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count == reportLength else {
            throw NuPhyProtocolError.invalidReportLength
        }
        return bytes
    }

    public static func checksum(_ report: [UInt8]) -> UInt8 {
        report.dropFirst(4).reduce(0, &+)
    }

    public static func temporarySessionRequest(challenge: [UInt8]) throws -> [UInt8] {
        guard challenge.count == payloadLength else {
            throw NuPhyProtocolError.invalidReportLength
        }
        var report = Array(repeating: UInt8(0), count: reportLength)
        report[0] = hostDirection
        report[1] = temporarySessionCommand
        report.replaceSubrange(8..<reportLength, with: challenge)
        report[3] = checksum(report)
        return report
    }

    public static func validateTemporarySession(
        _ response: [UInt8],
        challenge: [UInt8]
    ) throws -> NuPhySessionKey {
        try validateEnvelope(response, command: temporarySessionCommand)
        guard challenge.count == payloadLength else {
            throw NuPhyProtocolError.invalidReportLength
        }
        let key = NuPhySessionKey(response[4])
        guard response[4..<8].allSatisfy({ $0 == key.value }) else {
            throw NuPhyProtocolError.sessionMismatch
        }
        for index in challenge.indices where response[index + 8] != challenge[index] ^ key.value {
            throw NuPhyProtocolError.sessionMismatch
        }
        return key
    }

    public static func validate(
        _ response: [UInt8],
        for request: NuPhyRequest,
        key: NuPhySessionKey
    ) throws -> [UInt8] {
        try validateEnvelope(response, command: request.command.rawValue)
        let length = response[4] ^ key.value
        let address = UInt16(response[5] ^ key.value)
            | (UInt16(response[6] ^ key.value) << 8)
        let handle = response[7] ^ key.value
        guard length == request.responseLength else {
            throw NuPhyProtocolError.responseLengthMismatch
        }
        guard address == request.address else {
            throw NuPhyProtocolError.responseAddressMismatch
        }
        guard handle == 0 else {
            throw NuPhyProtocolError.responseHandleMismatch
        }
        return response[8..<(8 + Int(length))].map { $0 ^ key.value }
    }

    private static func validateEnvelope(_ response: [UInt8], command: UInt8) throws {
        guard response.count == reportLength else {
            throw NuPhyProtocolError.invalidReportLength
        }
        guard response[0] == deviceDirection else {
            throw NuPhyProtocolError.invalidDirection
        }
        guard response[1] == command else {
            throw NuPhyProtocolError.commandMismatch
        }
        guard response[3] == checksum(response) else {
            throw NuPhyProtocolError.checksumMismatch
        }
    }
}
