import Foundation

public struct SignalColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum SignalPattern: Equatable, Sendable {
    case steady
    case slowFlashing
}

public struct SignalBrightness: Equatable, Sendable {
    public let percent: UInt8

    public init?(percent: UInt8) {
        guard (1...100).contains(percent) else { return nil }
        self.percent = percent
    }

    private init(unchecked percent: UInt8) {
        self.percent = percent
    }

    public static let full = SignalBrightness(unchecked: 100)
}

public struct CompletionDisplayDuration: Equatable, Sendable {
    public let seconds: UInt8

    public init?(seconds: UInt8) {
        guard (1...60).contains(seconds) else { return nil }
        self.seconds = seconds
    }

    private init(unchecked seconds: UInt8) {
        self.seconds = seconds
    }

    public static let fiveSeconds = CompletionDisplayDuration(unchecked: 5)
}

public struct SignalAppearance: Equatable, Sendable {
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

public struct LocalProfile: Equatable, Sendable {
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
