import Foundation

public enum VIAProtocolError: Error, Equatable, Sendable {
    case invalidReport
    case invalidDescriptor
    case unhandledCommand
    case mismatchedResponse
    case unsupportedVersion(UInt16)
    case responseTimedOut
    case readbackMismatch
    case unsupportedEffect(UInt8)
}

// Wire facts from NuPhy's QMK fork, commit 0f6d5f7; see docs/research/air75-v2-via.md.
// This boundary exposes only version and the RGB Matrix channel, never SAVE or keymap commands.
enum VIAProtocol {
    enum Value: UInt8, CaseIterable {
        case brightness = 1, effect, speed, color
        var length: Int { self == .color ? 2 : 1 }
    }

    enum Request {
        case version
        case get(Value)
        case set(Value, [UInt8])

        var packet: [UInt8] {
            get throws {
                let prefix: [UInt8]
                switch self {
                case .version: prefix = [1]
                case .get(let value): prefix = [8, 3, value.rawValue]
                case .set(let value, let data):
                    guard data.count == value.length else { throw VIAProtocolError.invalidReport }
                    if value == .effect, Int(data[0]) >= NativeLightingEffect.viaCatalog.count {
                        throw VIAProtocolError.unsupportedEffect(data[0])
                    }
                    prefix = [7, 3, value.rawValue] + data
                }
                return prefix + Array(repeating: 0, count: 32 - prefix.count)
            }
        }

        func validate(_ response: [UInt8]) throws -> [UInt8] {
            guard response.count == 32 else { throw VIAProtocolError.invalidReport }
            guard response[0] != 0xff else { throw VIAProtocolError.unhandledCommand }
            switch self {
            case .version:
                guard response[0] == 1 else { throw VIAProtocolError.mismatchedResponse }
                let version = UInt16(response[1]) << 8 | UInt16(response[2])
                guard version == 12 else { throw VIAProtocolError.unsupportedVersion(version) }
                return Array(response[1...2])
            case .get(let value):
                guard try response.prefix(3).elementsEqual(packet.prefix(3)) else { throw VIAProtocolError.mismatchedResponse }
                if value == .effect, Int(response[3]) >= NativeLightingEffect.viaCatalog.count {
                    throw VIAProtocolError.unsupportedEffect(response[3])
                }
                return Array(response[3..<(3 + value.length)])
            case .set:
                guard try response == packet else { throw VIAProtocolError.mismatchedResponse }
                return [] // Echo is only acknowledgement; the adapter must issue independent GETs.
            }
        }
    }

    static let reportDescriptor: [UInt8] = [
        0x06, 0x60, 0xff, 0x09, 0x61, 0xa1, 0x01, 0x09, 0x62, 0x15, 0x00,
        0x26, 0xff, 0x00, 0x95, 0x20, 0x75, 0x08, 0x81, 0x02, 0x09, 0x63,
        0x15, 0x00, 0x26, 0xff, 0x00, 0x95, 0x20, 0x75, 0x08, 0x91, 0x02, 0xc0,
    ]

    static func validateDescriptor(_ descriptor: [UInt8], inputSize: Int?, outputSize: Int?) throws {
        guard descriptor == reportDescriptor, inputSize == 32, outputSize == 32 else {
            throw VIAProtocolError.invalidDescriptor
        }
    }

    // SET and GET both use 0...255, but firmware quantizes through its internal brightness range.
    // The physical V2 returned 76 for SET 77. Allow at most one rounded UI percent step (3/255),
    // without assuming the installed firmware uses the source snapshot's maximum of 128.
    static func brightnessMatches(_ observed: UInt8, requested: UInt8) -> Bool {
        abs(Int(observed) - Int(requested)) <= 3
    }

    static func hsv(for color: SignalColor) -> (hue: UInt8, saturation: UInt8) {
        let r = Double(color.red), g = Double(color.green), b = Double(color.blue)
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        guard delta > 0 else { return (0, 0) }
        let sector: Double
        if high == r { sector = (g - b) / delta }
        else if high == g { sector = (b - r) / delta + 2 }
        else { sector = (r - g) / delta + 4 }
        let hue = (sector + 6).truncatingRemainder(dividingBy: 6) / 6
        return (UInt8((hue * 255).rounded()), UInt8((delta / high * 255).rounded()))
    }
}
