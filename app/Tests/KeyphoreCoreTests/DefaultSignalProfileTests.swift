import Foundation
import KeyphoreCore
import XCTest

final class DefaultSignalProfileTests: XCTestCase {
    func testDefaultOwnsOnlyBacklightAndUsesNativeEffects() {
        let profile = LocalProfile.default
        XCTAssertEqual(profile.controlledZones, .backlight)
        XCTAssertEqual(profile.execution.backlight.effect, .backlightBreathing)
        XCTAssertEqual(profile.attention.backlight.effect, .backlightBreathing)
        XCTAssertEqual(profile.completion.backlight.effect, .backlightStatic)
        XCTAssertEqual(profile.execution.backlight.color, SignalColor(red: 0, green: 0, blue: 255))
        XCTAssertEqual(profile.signalOff.strip, .unmanaged)
        XCTAssertEqual(profile.completionDisplayDuration, .fiveSeconds)
    }

    func testIdleDefaultsOffWithIndependentGentleNativeSettings() {
        let idle = LocalProfile.default.idle
        XCTAssertEqual(idle, LocalProfile.defaultIdle)
        XCTAssertFalse(idle.isVisible)
        XCTAssertEqual(idle.backlight.effect, .backlightBreathing)
        XCTAssertEqual(idle.strip.effect, .stripBreathing)
        XCTAssertEqual(idle.backlight.brightness.percent, 30)
        XCTAssertEqual(idle.strip.brightness.percent, 30)
        XCTAssertEqual(LightingBehavior.signal(idle), .off)
        XCTAssertEqual(LightingPreset.allCases, [.execution, .attention, .completion, .idle])
    }

    func testPresetAndZoneEditsRetainIndependentIdleAppearance() {
        let idle = testSignalAppearance(color: SignalColor(red: 10, green: 20, blue: 30))
        let profile = LocalProfile.default.replacingAppearance(idle, forPreset: .idle)
        XCTAssertEqual(profile.appearance(forPreset: .idle), idle)
        XCTAssertEqual(profile.signalOff, .off)
        XCTAssertEqual(profile.replacingControlledZones(.both).idle, idle)
        for signal in [CodexSignal.execution, .attention, .completion] {
            XCTAssertEqual(profile.replacingAppearance(LocalProfile.default.completion, for: signal).idle, idle)
        }
        for preset in [LightingPreset.execution, .attention, .completion] {
            XCTAssertEqual(profile.replacingAppearance(LocalProfile.default.attention, forPreset: preset).idle, idle)
        }
    }

    func testOfficialMechanicalCatalogAndControlRanges() throws {
        XCTAssertEqual(NativeLightingEffect.backlightRipple.wireID, 11)
        XCTAssertEqual(NativeLightingEffect.backlightSinglePoint.wireID, 12)
        XCTAssertEqual(NativeLightingEffect.backlightWaveBand.wireID, 16)
        XCTAssertEqual(NativeLightingEffect.backlightDiagonal.wireID, 20)
        XCTAssertEqual(NativeLightingEffect.catalog(for: .strip).compactMap(\.wireID), [3, 4, 0, 1, 2])
        XCTAssertEqual(NativeLightingEffect.catalog(for: .backlight).compactMap(\.wireID), Array(1...20))
        XCTAssertTrue(NativeLightingEffect.backlightSpectrum.supportsColor)
        XCTAssertTrue(NativeLightingEffect.backlightFlowers.supportsColor)
        XCTAssertFalse(NativeLightingEffect.stripRhythm.supportsSpeed)
        XCTAssertFalse(NativeLightingEffect.backlightGaming.supportsMulticolor)
        XCTAssertEqual(LightingDirection.forward.rawValue, 1)
        XCTAssertNotNil(SignalBrightness(percent: 0))
        XCTAssertNil(SignalBrightness(percent: 101))
        XCTAssertNil(LightingSpeed(level: 5))
        XCTAssertNil(CompletionDisplayDuration(seconds: 0))
        XCTAssertNil(CompletionDisplayDuration(seconds: 61))
        for effect in NativeLightingEffect.allCases {
            let appearance = ZoneAppearance(effect: effect, color: SignalColor(red: 139, green: 139, blue: 255))
            XCTAssertEqual(try JSONDecoder().decode(ZoneAppearance.self, from: JSONEncoder().encode(appearance)), appearance)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(LightingSpeed.self, from: Data("5".utf8)))
    }
}

// Historical lifecycle/protocol fixtures keep their explicit static packet settings.
extension LocalProfile {
    static var steadyTestProfile: LocalProfile {
        let profile = LocalProfile.default
        return LocalProfile(execution: testSignalAppearance(color: profile.execution.backlight.color),
                            attention: testSignalAppearance(color: profile.attention.backlight.color),
                            completion: testSignalAppearance(color: profile.completion.backlight.color),
                            completionDisplayDuration: profile.completionDisplayDuration)
    }
}

func testSignalAppearance(color: SignalColor, brightness: SignalBrightness = .full, isVisible: Bool = true) -> SignalAppearance {
    SignalAppearance(isVisible: isVisible,
                     backlight: ZoneAppearance(effect: .backlightStatic, color: color, colorMode: .multicolor,
                                               brightness: brightness, speed: LightingSpeed(level: 1)!),
                     strip: ZoneAppearance(effect: .stripStatic, color: color))
}

final class NativeLightingFixture {
    let directory: URL
    let status: DurableStatusStore
    let profiles: LocalProfileStore
    let ownership: LightingOwnershipStore
    let preview: SignalPreviewStore
    let health: KeyboardHealthStore
    let acknowledgement: SignalOffAcknowledgementStore
    let quit: QuitGateStore
    let lighting = NativeTestLighting()

    init(profile: LocalProfile = .default) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        status = DurableStatusStore(url: directory.appending(path: "status.json"))
        profiles = LocalProfileStore(url: directory.appending(path: "profile.json"))
        ownership = LightingOwnershipStore(url: directory.appending(path: "ownership.json"))
        preview = SignalPreviewStore(url: directory.appending(path: "preview.json"))
        health = KeyboardHealthStore(url: directory.appending(path: "health.json"))
        acknowledgement = SignalOffAcknowledgementStore(url: directory.appending(path: "off"))
        quit = QuitGateStore(url: directory.appending(path: "quit"))
        try profiles.save(profile)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func companion(profileProvider: (() throws -> LocalProfile)? = nil) -> KeyphoreCompanion {
        let provider = profileProvider ?? { [profiles] in try profiles.load() }
        return KeyphoreCompanion(store: status, profileProvider: { _ in try provider() },
                         lighting: lighting, keyboardHealthStore: health, previewStore: preview,
                         signalOffAcknowledgement: acknowledgement, quitGate: quit, ownershipStore: ownership)
    }

    func signal(_ signal: CodexSignal = .execution) throws {
        try status.recordSignal(ownerID: SignalOwnerID(product: "codex", sessionID: "session", agentID: "main"),
                                turnID: "turn", signal: signal, expiresAt: .milliseconds(100_000),
                                replacingSession: true, lockBudget: .milliseconds(100))
    }
}

final class NativeTestLighting: CompanionLightingEvidenceApplying, CompanionLightingVerifying, CompanionLightingRecovering, CompanionKeyboardIdentifying {
    var connectedModel: SupportedKeyboardModel? { .air75V3 }
    var behaviors: [LightingBehavior] = []
    var checked: [LightingBehavior] = []
    var actual: LightingBehavior?
    var error: Error?
    var displaysExpected = true
    var preserved = true
    var protection: UnmanagedZoneProtection = .readback
    var invalidations = 0
    var willApply: (LightingBehavior) throws -> Void = { _ in }
    var didApply: () -> Void = {}

    func apply(_ behavior: LightingBehavior) throws { _ = try applyAndVerify(behavior) }

    func applyAndVerify(_ behavior: LightingBehavior) throws -> NuPhyIOEvidence {
        try willApply(behavior)
        if let error { throw error }
        behaviors.append(behavior)
        actual = behavior
        didApply()
        return NuPhyIOEvidence(protocolReadbackSucceeded: true, visualConfirmation: .notRequested,
                               mainState: [], rhythmBefore: [1, 2, 3], rhythmAfter: [4, 5, 6],
                               unmanagedZonesPreserved: preserved, unmanagedZoneProtection: protection)
    }

    func displays(_ behavior: LightingBehavior) throws -> Bool {
        if let error { throw error }
        checked.append(behavior)
        return displaysExpected && behavior == actual
    }

    func invalidateTransport() { invalidations += 1 }
}
