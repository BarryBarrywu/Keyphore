import XCTest
@testable import KeyphoreCore

final class VIAEffectCatalogTests: XCTestCase {
    func testCatalogExactlyMatchesTheSuppliedVIAEffectMenuAndParameterVisibility() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "nuphy-air75-v2-via3", withExtension: "json", subdirectory: "Fixtures"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let menus = try XCTUnwrap(root["menus"] as? [[String: Any]])
        let sections = try XCTUnwrap(menus.first?["content"] as? [[String: Any]])
        let controls = try XCTUnwrap(sections.first?["content"] as? [[String: Any]])
        let effectControl = try XCTUnwrap(controls.first { $0["label"] as? String == "Effect" })
        let fields = try XCTUnwrap(effectControl["content"] as? [Any])
        XCTAssertEqual(fields[0] as? String, "id_qmk_rgb_matrix_effect")
        XCTAssertEqual(fields[1] as? Int, 3)
        XCTAssertEqual(fields[2] as? Int, 2)
        let names = try XCTUnwrap(effectControl["options"] as? [String])
        let mapping: [String: NativeLightingEffect] = [
            "All Off": .viaOff, "Solid Color": .backlightStatic,
            "Gradient Up/Down": .viaGradientUpDown, "Gradient Left/Right": .viaGradientLeftRight,
            "Breathing": .backlightBreathing, "Band Sat.": .viaBandSaturation, "Band Val.": .viaBandValue,
            "Pinwheel Sat.": .viaPinwheelSaturation, "Pinwheel Val.": .viaPinwheelValue,
            "Spiral Sat.": .viaSpiralSaturation, "Spiral Val.": .viaSpiralValue,
            "Cycle All": .viaCycleAll, "Cycle Left/Right": .viaCycleLeftRight, "Cycle Up/Down": .viaCycleUpDown,
            "Rainbow Moving Chevron": .viaRainbowMovingChevron, "Cycle Out/In": .viaCycleOutIn,
            "Cycle Out/In Dual": .viaCycleOutInDual, "Cycle Pinwheel": .viaCyclePinwheel,
            "Cycle Spiral": .viaCycleSpiral, "Dual Beacon": .viaDualBeacon,
            "Rainbow Beacon": .viaRainbowBeacon, "Rainbow Pinwheels": .viaRainbowPinwheels,
            "Raindrops": .viaRaindrops, "Jellybean Raindrops": .viaJellybeanRaindrops,
            "Hue Breathing": .viaHueBreathing, "Hue Pendulum": .viaHuePendulum, "Hue Wave": .viaHueWave,
            "Typing Heatmap": .viaTypingHeatmap, "Digital Rain": .viaDigitalRain,
            "Reactive Simple": .viaReactiveSimple, "Reactive": .viaReactive,
            "Reactive Wide": .viaReactiveWide, "Reactive Multiwide": .viaReactiveMultiwide,
            "Reactive Cross": .viaReactiveCross, "Reactive Multicross": .viaReactiveMulticross,
            "Reactive Nexus": .viaReactiveNexus, "Reactive MultiNexus": .viaReactiveMultiNexus,
            "Splash": .viaSplash, "MultiSplash": .viaMultiSplash,
            "Solid Splash": .viaSolidSplash, "Solid MultiSplash": .viaSolidMultiSplash,
        ]
        XCTAssertEqual(names.count, 41)
        XCTAssertEqual(mapping.count, 41)
        XCTAssertEqual(Set(NativeLightingEffect.viaCatalog).count, 41)
        for (id, name) in names.enumerated() {
            let effect = try XCTUnwrap(mapping[name])
            XCTAssertEqual(effect.viaWireID, UInt8(id), name)
            XCTAssertEqual(NativeLightingEffect.viaCatalog[id], effect, name)
            XCTAssertEqual(SupportedKeyboardModel.air75V2.supportsColor(for: effect), id != 0)
            XCTAssertEqual(SupportedKeyboardModel.air75V2.supportsSpeed(for: effect), id != 0)
            XCTAssertFalse(SupportedKeyboardModel.air75V2.supportsMulticolor(for: effect))
            XCTAssertFalse(SupportedKeyboardModel.air75V2.supportsDirection(for: effect))
        }
        for label in ["Effect Speed", "Color"] {
            XCTAssertEqual(controls.first { $0["label"] as? String == label }?["showIf"] as? String,
                           "{id_qmk_rgb_matrix_effect} != 0")
        }
        XCTAssertEqual(SupportedKeyboardModel.air75V2.supportedEffects(for: .backlight), NativeLightingEffect.viaCatalog)
        XCTAssertTrue(SupportedKeyboardModel.air75V2.supportedEffects(for: .strip).isEmpty)
    }

    func testVIAOnlyCasesHaveNoV3WireIDAndSavedSharedEffectsKeepTheirIdentity() throws {
        XCTAssertEqual(NativeLightingEffect.backlightStatic.rawValue, "backlightStatic")
        XCTAssertEqual(NativeLightingEffect.backlightBreathing.rawValue, "backlightBreathing")
        for effect in NativeLightingEffect.viaCatalog {
            XCTAssertEqual(try JSONDecoder().decode(NativeLightingEffect.self, from: JSONEncoder().encode(effect)), effect)
            if effect != .backlightStatic && effect != .backlightBreathing {
                XCTAssertNil(effect.wireID)
                XCTAssertFalse(SupportedKeyboardModel.air75V3.supportedEffects(for: .backlight).contains(effect))
            }
        }
        XCTAssertNil(NativeLightingEffect.backlightWave.viaWireID)
        XCTAssertThrowsError(try JSONDecoder().decode(NativeLightingEffect.self, from: Data("\"viaUnknown\"".utf8)))
    }

    func testOffRemainsPersistableAndUnlitEvenWithNonzeroBrightness() throws {
        let off = ZoneAppearance(effect: .viaOff, color: SignalColor(red: 255, green: 0, blue: 0))
        let appearance = LocalProfile.default.completion.replacingAppearance(off, for: .backlight)
        let profile = LocalProfile.default.replacingAppearance(appearance, for: .completion)
        XCTAssertEqual(try JSONDecoder().decode(LocalProfile.self, from: JSONEncoder().encode(profile)), profile)
        XCTAssertTrue(LightingBehavior.signal(appearance).isOff)
        XCTAssertFalse(LightingBehavior.signal(appearance, controlledZones: .both).isOff,
                       "An Off main backlight must not hide a managed, lit strip")
        let fixture = try NativeLightingFixture(profile: profile)
        _ = try fixture.preview.begin(preset: .completion, at: .milliseconds(0))
        let controller = SignalPreviewController(store: fixture.preview, lighting: fixture.lighting)
        XCTAssertEqual(try controller.poll(at: .milliseconds(0), profile: profile), .active)
        XCTAssertFalse(try XCTUnwrap(fixture.preview.load()).presentationIsLit)
    }

    func testInvalidVIAEffectIDsAndPayloadLengthsAreRejectedWithoutTraps() throws {
        for id: UInt8 in [41, 127, 255] {
            XCTAssertThrowsError(try VIAProtocol.Request.set(.effect, [id]).packet) {
                XCTAssertEqual($0 as? VIAProtocolError, .unsupportedEffect(id))
            }
            var response = try VIAProtocol.Request.get(.effect).packet
            response[3] = id
            XCTAssertThrowsError(try VIAProtocol.Request.get(.effect).validate(response))
        }
        XCTAssertThrowsError(try VIAProtocol.Request.set(.effect, []).packet)
        XCTAssertThrowsError(try VIAProtocol.Request.set(.color, [1]).packet)
        XCTAssertThrowsError(try VIAProtocol.Request.set(.brightness, [1, 2]).packet)
    }
}
