import Foundation

public struct SignalColor: Codable, Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum SignalPattern: String, CaseIterable, Codable, Equatable, Sendable {
    case steady
    case slowFlashing
}

public struct SignalBrightness: Codable, Equatable, Sendable {
    public let percent: UInt8

    public init?(percent: UInt8) {
        guard (1...100).contains(percent) else { return nil }
        self.percent = percent
    }

    private init(unchecked percent: UInt8) {
        self.percent = percent
    }

    public static let full = SignalBrightness(unchecked: 100)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let percent = try container.decode(UInt8.self, forKey: .percent)
        guard let value = SignalBrightness(percent: percent) else {
            throw DecodingError.dataCorruptedError(
                forKey: .percent,
                in: container,
                debugDescription: "Signal brightness must be between 1 and 100."
            )
        }
        self = value
    }

    private enum CodingKeys: String, CodingKey {
        case percent
    }
}

public struct CompletionDisplayDuration: Codable, Equatable, Sendable {
    public let seconds: UInt8

    public init?(seconds: UInt8) {
        guard (1...60).contains(seconds) else { return nil }
        self.seconds = seconds
    }

    private init(unchecked seconds: UInt8) {
        self.seconds = seconds
    }

    public static let fiveSeconds = CompletionDisplayDuration(unchecked: 5)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let seconds = try container.decode(UInt8.self, forKey: .seconds)
        guard let value = CompletionDisplayDuration(seconds: seconds) else {
            throw DecodingError.dataCorruptedError(
                forKey: .seconds,
                in: container,
                debugDescription: "Completion display duration must be between 1 and 60 seconds."
            )
        }
        self = value
    }

    private enum CodingKeys: String, CodingKey {
        case seconds
    }
}

public struct SignalAppearance: Codable, Equatable, Sendable {
    public let isVisible: Bool
    public let color: SignalColor
    public let brightness: SignalBrightness
    public let pattern: SignalPattern

    public init(
        isVisible: Bool,
        color: SignalColor,
        brightness: SignalBrightness,
        pattern: SignalPattern
    ) {
        self.isVisible = isVisible
        self.color = color
        self.brightness = brightness
        self.pattern = pattern
    }
}

public enum LightingBehavior: Equatable, Sendable {
    case signal(SignalAppearance)
    case off
}

public struct LocalProfile: Codable, Equatable, Sendable {
    public let execution: SignalAppearance
    public let attention: SignalAppearance
    public let completion: SignalAppearance
    public let completionDisplayDuration: CompletionDisplayDuration
    public var signalOff: LightingBehavior { .off }

    public init(
        execution: SignalAppearance,
        attention: SignalAppearance,
        completion: SignalAppearance,
        completionDisplayDuration: CompletionDisplayDuration
    ) {
        self.execution = execution
        self.attention = attention
        self.completion = completion
        self.completionDisplayDuration = completionDisplayDuration
    }

    public static let `default` = LocalProfile(
        execution: SignalAppearance(
            isVisible: true,
            color: SignalColor(red: 0, green: 0, blue: 255),
            brightness: .full,
            pattern: .steady
        ),
        attention: SignalAppearance(
            isVisible: true,
            color: SignalColor(red: 255, green: 132, blue: 0),
            brightness: .full,
            pattern: .steady
        ),
        completion: SignalAppearance(
            isVisible: true,
            color: SignalColor(red: 0, green: 255, blue: 0),
            brightness: .full,
            pattern: .steady
        ),
        completionDisplayDuration: .fiveSeconds
    )
}

public final class LocalProfileStore: @unchecked Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> LocalProfile {
        do {
            return try JSONDecoder().decode(LocalProfile.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return .default
        }
    }

    public func loadOrDefault() -> LocalProfile {
        (try? load()) ?? .default
    }

    public func save(_ profile: LocalProfile) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(profile).write(to: url, options: .atomic)
    }
}

extension LocalProfile {
    public func appearance(for signal: CodexSignal) -> SignalAppearance {
        switch signal {
        case .execution: execution
        case .attention: attention
        case .completion: completion
        }
    }

    public func replacingAppearance(
        _ appearance: SignalAppearance,
        for signal: CodexSignal
    ) -> LocalProfile {
        switch signal {
        case .execution:
            LocalProfile(
                execution: appearance,
                attention: attention,
                completion: completion,
                completionDisplayDuration: completionDisplayDuration
            )
        case .attention:
            LocalProfile(
                execution: execution,
                attention: appearance,
                completion: completion,
                completionDisplayDuration: completionDisplayDuration
            )
        case .completion:
            LocalProfile(
                execution: execution,
                attention: attention,
                completion: appearance,
                completionDisplayDuration: completionDisplayDuration
            )
        }
    }

    func aggregateSignal(for outcome: DurableStatusOutcome) -> AggregateSignal {
        if outcome.activeSignals.contains(.attention), attention.isVisible {
            return .attention
        }
        if outcome.activeSignals.contains(.execution), execution.isVisible {
            return .execution
        }
        if outcome.activeSignals.contains(.completion), completion.isVisible {
            return .completion
        }
        return .signalOff
    }

    func behavior(for signal: AggregateSignal) -> LightingBehavior {
        switch signal {
        case .signalOff:
            signalOff
        case .execution:
            .signal(execution)
        case .attention:
            .signal(attention)
        case .completion:
            .signal(completion)
        }
    }

    func behavior(for signal: AggregateSignal, at timestamp: StatusTimestamp) -> LightingBehavior {
        let configured = behavior(for: signal)
        guard case .signal(let appearance) = configured else { return configured }
        guard appearance.pattern == .slowFlashing else { return configured }
        guard timestamp.millisecondsSince1970 / 1_000 % 2 == 0 else { return .off }
        return .signal(appearance.replacingPattern(with: .steady))
    }
}

extension SignalAppearance {
    func replacingPattern(with pattern: SignalPattern) -> SignalAppearance {
        SignalAppearance(
            isVisible: isVisible,
            color: color,
            brightness: brightness,
            pattern: pattern
        )
    }
}
