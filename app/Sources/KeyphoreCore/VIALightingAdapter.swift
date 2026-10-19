import Foundation

// The shared NuPhyIOAdapter owns discovery, model selection, and transport recovery.
// This backend only uses the selected Air75 V2 transport and cannot control a side-light channel.
struct VIALightingAdapter {
    let transport: any Air65ReportTransport

    func inspect() throws -> [UInt8] {
        _ = try exchange(.version)
        return try readState().bytes
    }

    static func validate(_ behavior: LightingBehavior) throws {
        func reject(_ reason: String) throws {
            throw LightingCapabilityError(model: .air75V2, reason: reason)
        }
        guard behavior.strip == .unmanaged else { try reject("Air75 V2 supports main backlight only"); return }
        if case .signal(let appearance) = behavior.backlight {
            guard SupportedKeyboardModel.air75V2.supportedEffects(for: .backlight).contains(appearance.effect) else {
                try reject("Effect is not in the Air75 V2 VIA catalog"); return
            }
            guard appearance.colorMode == .custom, appearance.direction == .forward else {
                try reject("Air75 V2 does not support multicolor or direction controls"); return
            }
        }
    }

    func applyAndVerify(_ behavior: LightingBehavior) throws -> NuPhyIOEvidence {
        try Self.validate(behavior)
        _ = try exchange(.version)
        let initial = try readState()
        if try !matches(initial, behavior: behavior) {
            switch behavior.backlight {
            case .unmanaged: break
            case .off:
                _ = try exchange(.set(.effect, [0]))
            case .signal(let appearance):
                let target = try target(for: appearance)
                if target.effect == 0 || target.brightness == 0 {
                    _ = try exchange(.set(.effect, [0]))
                } else {
                    // Disabled firmware ignores HSV setters. Enable first, then immediately dim;
                    // a brief previous-color flash on first enable cannot be excluded by this API.
                    if initial.effect == 0 { _ = try exchange(.set(.effect, [target.effect])) }
                    _ = try exchange(.set(.brightness, [0]))
                    if initial.effect != 0, initial.effect != target.effect {
                        _ = try exchange(.set(.effect, [target.effect]))
                    }
                    _ = try exchange(.set(.color, [target.hue, target.saturation]))
                    _ = try exchange(.set(.speed, [target.speed]))
                    _ = try exchange(.set(.brightness, [target.brightness]))
                }
            }
        }
        let verified = try readState()
        guard try matches(verified, behavior: behavior) else { throw VIAProtocolError.readbackMismatch }
        return NuPhyIOEvidence(protocolReadbackSucceeded: true, visualConfirmation: .notRequested,
            mainState: verified.bytes, rhythmBefore: [], rhythmAfter: [], unmanagedZonesPreserved: true,
            unmanagedZoneProtection: .untouchedProtocolChannel)
    }

    func displays(_ behavior: LightingBehavior) throws -> Bool {
        try Self.validate(behavior)
        _ = try exchange(.version)
        return try matches(readState(), behavior: behavior)
    }

    private struct State {
        let brightness: UInt8
        let effect: UInt8
        let speed: UInt8
        let hue: UInt8
        let saturation: UInt8
        var bytes: [UInt8] { [brightness, effect, speed, hue, saturation] }
    }

    private func target(for appearance: ZoneAppearance) throws -> State {
        guard let effect = appearance.effect.viaWireID else {
            throw LightingCapabilityError(model: .air75V2, reason: "Effect is not in the Air75 V2 VIA catalog")
        }
        let hsv = VIAProtocol.hsv(for: appearance.color)
        let value = Double(max(appearance.color.red, appearance.color.green, appearance.color.blue))
        return State(brightness: UInt8((value * Double(appearance.brightness.percent) / 100).rounded()),
            effect: effect,
            // Keep the existing five speed levels for every non-Off VIA mode.
            speed: (appearance.speed.level + 1) * 51, hue: hsv.hue, saturation: hsv.saturation)
    }

    private func matches(_ state: State, behavior: LightingBehavior) throws -> Bool {
        switch behavior.backlight {
        case .unmanaged: return true
        case .off: return state.effect == 0
        case .signal(let appearance):
            let expected = try target(for: appearance)
            if expected.effect == 0 || expected.brightness == 0 { return state.effect == 0 }
            return state.effect == expected.effect
                && VIAProtocol.brightnessMatches(state.brightness, requested: expected.brightness)
                && state.hue == expected.hue && state.saturation == expected.saturation
                && state.speed == expected.speed
        }
    }

    private func readState() throws -> State {
        let brightness = try exchange(.get(.brightness))[0]
        let effect = try exchange(.get(.effect))[0]
        let speed = try exchange(.get(.speed))[0]
        let color = try exchange(.get(.color))
        return State(brightness: brightness, effect: effect, speed: speed, hue: color[0], saturation: color[1])
    }

    private func exchange(_ request: VIAProtocol.Request) throws -> [UInt8] {
        try transport.send(request.packet)
        guard let response = try transport.receive(timeout: 1) else { throw VIAProtocolError.responseTimedOut }
        return try request.validate(response)
    }
}
