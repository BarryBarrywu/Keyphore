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

public enum LightingPreset: String, CaseIterable, Codable, Sendable {
    case execution
    case attention
    case completion
    case idle
}

public enum LightingZone: String, CaseIterable, Codable, Sendable {
    case backlight
    case strip
}

public enum ControlledZones: String, CaseIterable, Codable, Sendable {
    case backlight
    case strip
    case both

    public func contains(_ zone: LightingZone) -> Bool {
        self == .both || rawValue == zone.rawValue
    }
}

public enum SignalColorMode: String, CaseIterable, Codable, Sendable {
    case custom
    case multicolor
}

public enum LightingDirection: UInt8, CaseIterable, Codable, Sendable {
    case forward = 1
    case reverse = 0
}

public enum LightingDirectionAxis: Sendable {
    case horizontal
    case vertical
}

public struct LightingSpeed: Codable, Equatable, Sendable {
    public let level: UInt8

    public init?(level: UInt8) {
        guard level <= 4 else { return nil }
        self.level = level
    }

    public static let medium = LightingSpeed(level: 2)!

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(UInt8.self)
        guard let speed = LightingSpeed(level: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Lighting speed must be between 0 and 4.")
        }
        self = speed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(level)
    }
}

public enum NativeLightingEffect: String, CaseIterable, Codable, Sendable {
    case backlightSpectrum, backlightGradient, backlightStatic, backlightBreathing, backlightFlowers
    case backlightWave, backlightUpDownWave, backlightFountain, backlightGalaxy, backlightRotation
    case backlightRipple, backlightSinglePoint, backlightGrid, backlightFlowing, backlightRain
    case backlightWaveBand, backlightGaming, backlightIdentify, backlightWindmill, backlightDiagonal
    case stripBreathing, stripRhythm, stripFlowing, stripNeon, stripStatic
    case viaOff, viaGradientUpDown, viaGradientLeftRight
    case viaBandSaturation, viaBandValue, viaPinwheelSaturation, viaPinwheelValue
    case viaSpiralSaturation, viaSpiralValue, viaCycleAll, viaCycleLeftRight, viaCycleUpDown
    case viaRainbowMovingChevron, viaCycleOutIn, viaCycleOutInDual, viaCyclePinwheel, viaCycleSpiral
    case viaDualBeacon, viaRainbowBeacon, viaRainbowPinwheels, viaRaindrops, viaJellybeanRaindrops
    case viaHueBreathing, viaHuePendulum, viaHueWave, viaTypingHeatmap, viaDigitalRain
    case viaReactiveSimple, viaReactive, viaReactiveWide, viaReactiveMultiwide
    case viaReactiveCross, viaReactiveMulticross, viaReactiveNexus, viaReactiveMultiNexus
    case viaSplash, viaMultiSplash, viaSolidSplash, viaSolidMultiSplash

    // The supplied Air75 V2 VIA v3 definition lists these channel-3 effect IDs in order.
    // Similar V3 names are not interchangeable wire IDs. Only existing Solid/Breathing are shared.
    public static let viaCatalog: [NativeLightingEffect] = [
        .viaOff, .backlightStatic, .viaGradientUpDown, .viaGradientLeftRight, .backlightBreathing,
        .viaBandSaturation, .viaBandValue, .viaPinwheelSaturation, .viaPinwheelValue,
        .viaSpiralSaturation, .viaSpiralValue, .viaCycleAll, .viaCycleLeftRight, .viaCycleUpDown,
        .viaRainbowMovingChevron, .viaCycleOutIn, .viaCycleOutInDual, .viaCyclePinwheel, .viaCycleSpiral,
        .viaDualBeacon, .viaRainbowBeacon, .viaRainbowPinwheels, .viaRaindrops, .viaJellybeanRaindrops,
        .viaHueBreathing, .viaHuePendulum, .viaHueWave, .viaTypingHeatmap, .viaDigitalRain,
        .viaReactiveSimple, .viaReactive, .viaReactiveWide, .viaReactiveMultiwide,
        .viaReactiveCross, .viaReactiveMulticross, .viaReactiveNexus, .viaReactiveMultiNexus,
        .viaSplash, .viaMultiSplash, .viaSolidSplash, .viaSolidMultiSplash,
    ]

    public var viaWireID: UInt8? { Self.viaCatalog.firstIndex(of: self).map(UInt8.init) }
    public var isOff: Bool { self == .viaOff }

    public static func catalog(for zone: LightingZone) -> [NativeLightingEffect] {
        switch zone {
        case .backlight:
            [.backlightSpectrum, .backlightGradient, .backlightStatic, .backlightBreathing, .backlightFlowers,
             .backlightWave, .backlightUpDownWave, .backlightFountain, .backlightGalaxy, .backlightRotation,
             .backlightRipple, .backlightSinglePoint, .backlightGrid, .backlightFlowing, .backlightRain,
             .backlightWaveBand, .backlightGaming, .backlightIdentify, .backlightWindmill, .backlightDiagonal]
        case .strip:
            [.stripBreathing, .stripRhythm, .stripFlowing, .stripNeon, .stripStatic]
        }
    }

    public var zone: LightingZone { Self.catalog(for: .strip).contains(self) ? .strip : .backlight }

    public var wireID: UInt8? {
        switch self {
        case .stripBreathing: 3
        case .stripRhythm: 4
        case .stripFlowing: 0
        case .stripNeon: 1
        case .stripStatic: 2
        default: Self.catalog(for: .backlight).firstIndex(of: self).map { UInt8($0 + 1) }
        }
    }

    public var supportsColor: Bool {
        !isOff && ![Self.backlightWaveBand, .backlightDiagonal, .stripNeon].contains(self)
    }

    public var supportsMulticolor: Bool {
        wireID != nil && supportsColor && ![Self.backlightGaming, .backlightIdentify, .backlightWindmill].contains(self)
    }

    public var supportsSpeed: Bool {
        !isOff && ![Self.backlightGradient, .backlightStatic, .stripBreathing, .stripRhythm, .stripStatic].contains(self)
    }

    public var directionAxis: LightingDirectionAxis? {
        switch self {
        case .backlightWave, .backlightFountain: .horizontal
        case .backlightUpDownWave, .backlightRotation: .vertical
        default: nil
        }
    }
}

public struct SignalBrightness: Codable, Equatable, Sendable {
    public let percent: UInt8

    public init?(percent: UInt8) {
        guard (0...100).contains(percent) else { return nil }
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
                debugDescription: "Signal brightness must be between 0 and 100."
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

public struct ZoneAppearance: Codable, Equatable, Sendable {
    public let effect: NativeLightingEffect
    public let color: SignalColor
    public let colorMode: SignalColorMode
    public let brightness: SignalBrightness
    public let speed: LightingSpeed
    public let direction: LightingDirection

    public init(effect: NativeLightingEffect, color: SignalColor, colorMode: SignalColorMode = .custom,
                brightness: SignalBrightness = .full, speed: LightingSpeed = .medium,
                direction: LightingDirection = .forward) {
        self.effect = effect
        self.color = color
        self.colorMode = colorMode
        self.brightness = brightness
        self.speed = speed
        self.direction = direction
    }
}

public struct SignalAppearance: Codable, Equatable, Sendable {
    public let isVisible: Bool
    public let backlight: ZoneAppearance
    public let strip: ZoneAppearance

    public init(isVisible: Bool, backlight: ZoneAppearance, strip: ZoneAppearance) {
        self.isVisible = isVisible
        self.backlight = backlight
        self.strip = strip
    }

    public func appearance(for zone: LightingZone) -> ZoneAppearance {
        zone == .backlight ? backlight : strip
    }

    public func replacingAppearance(_ appearance: ZoneAppearance, for zone: LightingZone) -> SignalAppearance {
        SignalAppearance(isVisible: isVisible, backlight: zone == .backlight ? appearance : backlight,
                         strip: zone == .strip ? appearance : strip)
    }
}

public enum ZoneLightingBehavior: Equatable, Sendable {
    case unmanaged
    case off
    case signal(ZoneAppearance)
}

public struct LightingBehavior: Equatable, Sendable {
    public let backlight: ZoneLightingBehavior
    public let strip: ZoneLightingBehavior

    public init(backlight: ZoneLightingBehavior, strip: ZoneLightingBehavior) {
        self.backlight = backlight
        self.strip = strip
    }

    public static var off: LightingBehavior { off(for: .backlight) }

    public static func off(for zones: ControlledZones) -> LightingBehavior {
        off(zones: Set(LightingZone.allCases.filter { zones.contains($0) }))
    }

    static func off(zones: Set<LightingZone>) -> LightingBehavior {
        LightingBehavior(backlight: zones.contains(.backlight) ? .off : .unmanaged,
                         strip: zones.contains(.strip) ? .off : .unmanaged)
    }

    public static func signal(_ appearance: SignalAppearance, controlledZones: ControlledZones = .backlight) -> LightingBehavior {
        guard appearance.isVisible else { return off(for: controlledZones) }
        return LightingBehavior(backlight: controlledZones.contains(.backlight) ? .signal(appearance.backlight) : .unmanaged,
                                strip: controlledZones.contains(.strip) ? .signal(appearance.strip) : .unmanaged)
    }

    public func behavior(for zone: LightingZone) -> ZoneLightingBehavior {
        zone == .backlight ? backlight : strip
    }

    public var isOff: Bool {
        [backlight, strip].allSatisfy {
            switch $0 {
            case .unmanaged, .off: true
            case .signal(let appearance): appearance.brightness.percent == 0 || appearance.effect.isOff
            }
        }
    }
}

public struct LocalProfile: Codable, Equatable, Sendable {
    public let execution: SignalAppearance
    public let attention: SignalAppearance
    public let completion: SignalAppearance
    public let idle: SignalAppearance
    public let completionDisplayDuration: CompletionDisplayDuration
    public let controlledZones: ControlledZones
    public var signalOff: LightingBehavior { .off(for: controlledZones) }

    public init(
        execution: SignalAppearance,
        attention: SignalAppearance,
        completion: SignalAppearance,
        idle: SignalAppearance = LocalProfile.defaultIdle,
        completionDisplayDuration: CompletionDisplayDuration,
        controlledZones: ControlledZones = .backlight
    ) {
        self.execution = execution
        self.attention = attention
        self.completion = completion
        self.idle = idle
        self.completionDisplayDuration = completionDisplayDuration
        self.controlledZones = controlledZones
    }

    public static let defaultIdle = SignalAppearance(isVisible: false,
        backlight: ZoneAppearance(effect: .backlightBreathing, color: SignalColor(red: 0, green: 0, blue: 255),
                                  brightness: SignalBrightness(percent: 30)!),
        strip: ZoneAppearance(effect: .stripBreathing, color: SignalColor(red: 0, green: 0, blue: 255),
                              brightness: SignalBrightness(percent: 30)!))

    public static let `default` = LocalProfile(
        execution: SignalAppearance(isVisible: true,
            backlight: ZoneAppearance(effect: .backlightBreathing, color: SignalColor(red: 0, green: 0, blue: 255)),
            strip: ZoneAppearance(effect: .stripBreathing, color: SignalColor(red: 0, green: 0, blue: 255))),
        attention: SignalAppearance(isVisible: true,
            backlight: ZoneAppearance(effect: .backlightBreathing, color: SignalColor(red: 255, green: 132, blue: 0)),
            strip: ZoneAppearance(effect: .stripRhythm, color: SignalColor(red: 255, green: 132, blue: 0))),
        completion: SignalAppearance(isVisible: true,
            backlight: ZoneAppearance(effect: .backlightStatic, color: SignalColor(red: 0, green: 255, blue: 0)),
            strip: ZoneAppearance(effect: .stripStatic, color: SignalColor(red: 0, green: 255, blue: 0))),
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

    public func appearance(forPreset preset: LightingPreset) -> SignalAppearance {
        switch preset {
        case .execution: execution
        case .attention: attention
        case .completion: completion
        case .idle: idle
        }
    }

    public func replacingAppearance(
        _ appearance: SignalAppearance,
        for signal: CodexSignal
    ) -> LocalProfile {
        switch signal {
        case .execution: replacingAppearance(appearance, forPreset: .execution)
        case .attention: replacingAppearance(appearance, forPreset: .attention)
        case .completion: replacingAppearance(appearance, forPreset: .completion)
        }
    }

    public func replacingAppearance(
        _ appearance: SignalAppearance,
        forPreset preset: LightingPreset
    ) -> LocalProfile {
        LocalProfile(execution: preset == .execution ? appearance : execution,
                     attention: preset == .attention ? appearance : attention,
                     completion: preset == .completion ? appearance : completion,
                     idle: preset == .idle ? appearance : idle,
                     completionDisplayDuration: completionDisplayDuration, controlledZones: controlledZones)
    }

    public func aggregateSignal(for outcome: DurableStatusOutcome) -> AggregateSignal {
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
            .signal(idle, controlledZones: controlledZones)
        case .execution:
            .signal(execution, controlledZones: controlledZones)
        case .attention:
            .signal(attention, controlledZones: controlledZones)
        case .completion:
            .signal(completion, controlledZones: controlledZones)
        }
    }

    public func replacingControlledZones(_ zones: ControlledZones) -> LocalProfile {
        LocalProfile(execution: execution, attention: attention, completion: completion, idle: idle,
                     completionDisplayDuration: completionDisplayDuration, controlledZones: zones)
    }
}
