import Foundation

public final class KeyboardHealthStore: @unchecked Sendable {
    public static let maximumAge = Duration.seconds(3)

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func save(_ health: KeyboardHealth, at timestamp: StatusTimestamp = .now) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let record: Record
        switch health {
        case .unverified(let interfaces):
            record = Record(status: .unverified, protocolHealthy: false, observedAt: timestamp, interfaces: interfaces)
        case .disconnected:
            record = Record(status: .disconnected, protocolHealthy: false, observedAt: timestamp)
        case .unavailable:
            record = Record(status: .unavailable, protocolHealthy: false, observedAt: timestamp)
        case .ambiguous:
            record = Record(status: .ambiguous, protocolHealthy: false, observedAt: timestamp)
        case .connected(let protocolHealthy):
            record = Record(
                status: .connected,
                protocolHealthy: protocolHealthy,
                observedAt: timestamp
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    public func load(at now: StatusTimestamp = .now) -> KeyboardHealth {
        loadFreshHealth(at: now) ?? .disconnected
    }

    public func loadDiagnosticHealth(at now: StatusTimestamp = .now) -> KeyboardHealth {
        loadFreshHealth(at: now) ?? .unavailable
    }

    private func loadFreshHealth(at now: StatusTimestamp) -> KeyboardHealth? {
        guard
            let data = try? Data(contentsOf: url),
            let record = try? JSONDecoder().decode(Record.self, from: data),
            record.observedAt <= now,
            now.millisecondsSince1970 - record.observedAt.millisecondsSince1970
                <= UInt64(Self.maximumAge.components.seconds * 1_000)
        else {
            return nil
        }
        switch record.status {
        case .unverified:
            guard let interfaces = record.interfaces, !interfaces.isEmpty else { return nil }
            return .unverified(interfaces)
        case .disconnected:
            return .disconnected
        case .unavailable:
            return .unavailable
        case .ambiguous:
            return .ambiguous
        case .connected:
            return .connected(protocolHealthy: record.protocolHealthy)
        }
    }

    private struct Record: Codable {
        enum Status: String, Codable {
            case disconnected
            case unverified
            case unavailable
            case ambiguous
            case connected
        }

        let status: Status
        let protocolHealthy: Bool
        let observedAt: StatusTimestamp
        var interfaces: [UnverifiedKeyboardInterface]? = nil
    }
}
