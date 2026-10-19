import AppKit
import KeyphoreCore
import SwiftUI
import XCTest

@MainActor
final class PopoverLayoutTests: XCTestCase {
    func testQuickKeyboardSelectionShowsAutoAndFreshModelsWithoutGrowingSingleKeyboardPanel() throws {
        let state = try keyboardSelectionState(inventory: [.init(model: .air75V2, count: 1)], active: .air75V2)
        XCTAssertEqual(state.keyboardSelectionOptions.map(\.model), [nil, .air75V2])
        XCTAssertNil(state.keyboardSelectionMessageKey)
        let picker = NSHostingController(rootView: KeyboardTargetQuickSelection(state: state).frame(width: 344))
        let pickerSize = picker.sizeThatFits(in: NSSize(width: 344, height: 0))
        XCTAssertLessThanOrEqual(pickerSize.height, 32)
        let hosting = NSHostingController(rootView: KeyphorePopover(state: state))
        let size = hosting.sizeThatFits(in: NSSize(width: 392, height: 0))
        XCTAssertEqual(size.width, 392, accuracy: 1)
        XCTAssertLessThanOrEqual(size.height, 440)
        attach(hosting.view, size: size, name: "single-keyboard-quick-selection")
    }

    func testMultipleKeyboardPopoverOffersChoicesAndAnExplicitSelectionPrompt() throws {
        let state = try keyboardSelectionState(inventory: [
            .init(model: .air75V2, count: 1), .init(model: .air75V3, count: 1),
        ], active: nil)
        XCTAssertEqual(state.keyboardSelectionOptions.map(\.model), [nil, .air75V3, .air75V2])
        XCTAssertEqual(state.keyboardSelectionMessageKey, .keyboardSelectionChooseTarget)
        XCTAssertTrue(state.canRequestKeyboardSelection(.air75V3))
        XCTAssertTrue(state.canRequestKeyboardSelection(.air75V2))
        let panel = KeyphorePopover(state: state)
        XCTAssertEqual(panel.statusDetail, AppCopy.value(.keyboardSelectionPopoverHint))
        XCTAssertEqual(panel.connectionDetail, .keyboardSelectionChooseTarget)
        let hosting = NSHostingController(rootView: panel)
        let size = hosting.sizeThatFits(in: NSSize(width: 392, height: 0))
        XCTAssertEqual(size.width, 392, accuracy: 1)
        XCTAssertLessThanOrEqual(size.height, 510)
        attach(hosting.view, size: size, name: "multiple-keyboard-quick-selection")
    }

    func testKeyboardSelectionDistinguishesDuplicatesEmptyInventoryAndDiscoveryFailure() throws {
        let duplicate = KeyboardSelectionSnapshot(desiredModel: nil, activeModel: nil,
            inventory: [.init(model: .air75V3, count: 2)], phase: .blocked, failure: .ambiguous)
        XCTAssertEqual(keyboardSelectionStatusKey(desired: nil, snapshot: duplicate, failed: false), .keyboardSelectionDuplicate)
        let empty = KeyboardSelectionSnapshot(desiredModel: nil, activeModel: nil, inventory: [], phase: .blocked, failure: .notFound)
        XCTAssertEqual(keyboardSelectionStatusKey(desired: nil, snapshot: empty, failed: false), .keyboardSelectionNoConnected)
        let failed = KeyboardSelectionSnapshot(desiredModel: nil, activeModel: nil, inventory: [], phase: .blocked, failure: .discoveryFailed)
        XCTAssertEqual(keyboardSelectionStatusKey(desired: nil, snapshot: failed, failed: false), .keyboardSelectionUnavailable)
        let unsupported = KeyboardSelectionSnapshot(desiredModel: nil, activeModel: nil, inventory: [], phase: .blocked, failure: .unsupportedSelection)
        XCTAssertEqual(keyboardSelectionStatusKey(desired: nil, snapshot: unsupported, failed: false), .keyboardSelectionUnsupported)
    }

    private func keyboardSelectionState(inventory: [KeyboardInventoryEntry], active: SupportedKeyboardModel?) throws -> KeyphoreAppState {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let selection = KeyboardSelectionStore(url: directory.appending(path: "selection.json"))
        let snapshots = KeyboardSelectionSnapshotStore(url: directory.appending(path: "snapshot.json"))
        try selection.save(nil)
        try snapshots.save(KeyboardSelectionSnapshot(desiredModel: nil, activeModel: active,
            inventory: inventory, phase: active == nil ? .blocked : .applied, failure: active == nil ? .ambiguous : nil))
        return KeyphoreAppState(lifecycle: KeyphoreLifecycle(health: SelectionLayoutHealth(model: active),
            profiles: LayoutProfile(profile: .default), durableStatus: LayoutStatus(),
            lighting: LayoutLighting(), runtime: LayoutRuntime()),
            keyboardSelectionStore: selection, keyboardSelectionSnapshotStore: snapshots,
            preferencesStore: AppPreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    func testDeviceCatalogIncludesSupportedAir75V2() {
        let air75V2 = CandidateKeyboardCatalogView.models.first { $0.name == "Air75 V2" }
        XCTAssertNotNil(air75V2)
        XCTAssertEqual(air75V2?.detailKey, .candidateAir75V2Detail)
    }

    func testKeyboardTargetOptionsRetainDisconnectedExplicitSelection() {
        let snapshot = KeyboardSelectionSnapshot(
            desiredModel: .air75V2,
            activeModel: .air75V3,
            inventory: [KeyboardInventoryEntry(model: .air75V3, count: 2)],
            phase: .blocked,
            failure: .notFound
        )

        XCTAssertEqual(keyboardTargetOptions(desired: .air75V2, snapshot: snapshot), [
            KeyboardTargetOption(model: nil, connectedCount: 2),
            KeyboardTargetOption(model: .air75V3, connectedCount: 2),
            KeyboardTargetOption(model: .air75V2, connectedCount: 0),
        ])
        XCTAssertEqual(
            keyboardSelectionStatusKey(desired: .air75V2, snapshot: snapshot, failed: false),
            .keyboardSelectionNotFound
        )
    }

    func testAir75V2SettingsExposeOnlySupportedLightingControls() {
        XCTAssertEqual(signalSettingsControlledZones(for: .air75V2), [.backlight])
        XCTAssertEqual(signalSettingsLightingZones(for: .air75V2), [.backlight, .strip])
        XCTAssertTrue(signalSettingsZoneIsEditable(.backlight, model: .air75V2))
        XCTAssertFalse(signalSettingsZoneIsEditable(.strip, model: .air75V2))
        XCTAssertEqual(signalSettingsEffects(for: .backlight, model: .air75V2), NativeLightingEffect.viaCatalog)
        XCTAssertEqual(NativeLightingEffect.viaCatalog.count, 41)
        XCTAssertEqual(NativeLightingEffect.viaCatalog.first, .viaOff)
        XCTAssertEqual(signalSettingsEffects(for: .backlight, model: .air75V3),
                       NativeLightingEffect.catalog(for: .backlight))
        XCTAssertEqual(signalSettingsEffects(for: .strip, model: .air75V2), [])
        XCTAssertEqual(keyboardLayout(for: .air75V2), .air75ANSI)
        XCTAssertEqual(
            keyboardIllustrationKey(for: .air75ANSI, model: .air75V2),
            .air75V2KeyboardIllustration
        )
        XCTAssertEqual(keyboardLightingHelp(for: .air75V2, isControlAvailable: true), .diagnosticChannelIsolation)
        XCTAssertEqual(keyboardLightingHelp(for: .air75V3, isControlAvailable: true), .rhythmLightUnchanged)
        XCTAssertEqual(signalSettingsControlledZones(for: .air75V3), ControlledZones.allCases)
    }

    func testAir75V2OffDisablesEffectControlsAndPreview() {
        XCTAssertFalse(SupportedKeyboardModel.air75V2.supportsColor(for: .viaOff))
        XCTAssertFalse(SupportedKeyboardModel.air75V2.supportsSpeed(for: .viaOff))
        XCTAssertTrue(SupportedKeyboardModel.air75V2.supportsColor(for: .viaReactive))
        XCTAssertTrue(SupportedKeyboardModel.air75V2.supportsSpeed(for: .viaReactive))

        let appearance = SignalAppearance(
            isVisible: true,
            backlight: ZoneAppearance(effect: .viaOff, color: SignalColor(red: 255, green: 0, blue: 0)),
            strip: LocalProfile.default.execution.strip
        )
        let presentation = KeyboardSignalPresentation(
            signal: .execution, appearance: appearance, controlledZones: .backlight
        )
        XCTAssertFalse(presentation.isLit)
        XCTAssertEqual(presentation.opacity(for: .backlight), 0)

        let profile = LocalProfile.default.replacingAppearance(appearance, forPreset: .execution)
        let snapshotPresentation = KeyboardSignalPresentation(snapshot: LifecycleSnapshot(
            health: .configured(keyboard: .connected(protocolHealthy: true, model: .air75V2)),
            menuState: .ready, durableStatus: .execution, currentSignal: .execution, profile: profile
        ), preview: nil)
        XCTAssertFalse(snapshotPresentation.isLit)
        XCTAssertEqual(snapshotPresentation.opacity(for: .backlight), 0)

        let idleOffProfile = LocalProfile(
            execution: profile.execution, attention: profile.attention, completion: profile.completion,
            idle: appearance, completionDisplayDuration: profile.completionDisplayDuration,
            controlledZones: .backlight
        )
        XCTAssertEqual(AggregateSignal.signalOff.presentation(in: idleOffProfile).copyKey, .signalOff)

        for zones in [ControlledZones.strip, .both] {
            let stripPresentation = KeyboardSignalPresentation(signal: .execution, appearance: appearance, controlledZones: zones)
            XCTAssertTrue(stripPresentation.isLit, "Off on the backlight must not hide a controlled strip")
            XCTAssertEqual(stripPresentation.opacity(for: .backlight), 0)
            XCTAssertGreaterThan(stripPresentation.opacity(for: .strip), 0)
            XCTAssertEqual(AggregateSignal.signalOff.presentation(in: idleOffProfile.replacingControlledZones(zones)).copyKey, .settingsIdle)
        }
        let zeroBrightness = appearance.replacingAppearance(ZoneAppearance(
            effect: .backlightStatic, color: SignalColor(red: 255, green: 0, blue: 0),
            brightness: SignalBrightness(percent: 0)!), for: .backlight)
        XCTAssertFalse(KeyboardSignalPresentation(signal: .execution, appearance: zeroBrightness,
                                                  controlledZones: .backlight).isLit)
        XCTAssertEqual(AggregateSignal.signalOff.presentation(in: idleOffProfile.replacingAppearance(
            zeroBrightness, forPreset: .idle)).copyKey, .signalOff)
    }

    func testEveryAir75V2EffectHasLocalizedLabelsAndExactEnglishReference() {
        let english = [
            "All Off", "Solid Color", "Gradient Up/Down", "Gradient Left/Right", "Breathing",
            "Band Sat.", "Band Val.", "Pinwheel Sat.", "Pinwheel Val.", "Spiral Sat.", "Spiral Val.",
            "Cycle All", "Cycle Left/Right", "Cycle Up/Down", "Rainbow Moving Chevron", "Cycle Out/In",
            "Cycle Out/In Dual", "Cycle Pinwheel", "Cycle Spiral", "Dual Beacon", "Rainbow Beacon",
            "Rainbow Pinwheels", "Raindrops", "Jellybean Raindrops", "Hue Breathing", "Hue Pendulum",
            "Hue Wave", "Typing Heatmap", "Digital Rain", "Reactive Simple", "Reactive", "Reactive Wide",
            "Reactive Multiwide", "Reactive Cross", "Reactive Multicross", "Reactive Nexus",
            "Reactive MultiNexus", "Splash", "MultiSplash", "Solid Splash", "Solid MultiSplash",
        ]
        XCTAssertEqual(
            NativeLightingEffect.viaCatalog.map {
                signalSettingsEffectLabel($0, language: .english, model: .air75V2)
            },
            english
        )
        for language in AppLanguage.allCases {
            for effect in NativeLightingEffect.viaCatalog {
                let label = signalSettingsEffectLabel(effect, language: language, model: .air75V2)
                XCTAssertFalse(label.isEmpty, "\(language) \(effect)")
                XCTAssertFalse(label.hasPrefix("effect."), "\(language) \(effect)")
            }
        }
    }

    func testSelectingAir75V2EffectClearsUnsupportedSavedDirection() {
        XCTAssertEqual(signalSettingsDirection(
            current: .reverse, requested: nil,
            effect: .backlightBreathing, model: .air75V2
        ), .forward)
        XCTAssertEqual(signalSettingsDirection(
            current: .reverse, requested: nil,
            effect: .backlightWave, model: .air75V3
        ), .reverse)
    }

    func testMulticolorModeKeepsNativeColorControlsVisible() throws {
        let appearance = ZoneAppearance(
            effect: .backlightBreathing,
            color: SignalColor(red: 0, green: 149, blue: 255),
            colorMode: .multicolor
        )
        let hosting = NSHostingController(rootView: NativeColorPanel(
            appearance: appearance, reset: {}, updateColorMode: { _ in }, updateColor: { _ in }
        ))
        let fitted = hosting.sizeThatFits(in: NSSize(width: 430, height: 600))
        XCTAssertGreaterThan(fitted.height, 250, "Multicolor mode must retain presets and the custom picker")
        hosting.view.frame = NSRect(origin: .zero, size: NSSize(width: 430, height: fitted.height))
        hosting.view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
        hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
        let containsOfficialOrange = (0..<bitmap.pixelsHigh).contains { y in
            (0..<bitmap.pixelsWide).contains { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return abs(color.redComponent * 255 - 255) < 2
                    && abs(color.greenComponent * 255 - 109) < 2
                    && abs(color.blueComponent * 255 - 30) < 2
            }
        }
        XCTAssertTrue(containsOfficialOrange, "The official color presets must remain visible")
    }

    func testHostedNativeKeyboardPreviewDoesNotInventPerKeyAnimation() throws {
        for controls: ControlActiveState in [.key, .inactive] {
            // Render the production preview itself, excluding unrelated settings controls and layout.
            let hosting = NSHostingController(rootView: Air65KeyboardView(presentation: KeyboardSignalPresentation(
                signal: .execution, appearance: LocalProfile.default.execution, controlledZones: .backlight
            ), layout: .air75ANSI)
                .frame(width: 180, height: 82)
                .environment(\.scenePhase, .background)
                .environment(\.controlActiveState, controls))
            let window = NSWindow(contentViewController: hosting)
            window.setContentSize(NSSize(width: 180, height: 82))
            var frames = Set<Data>()
            for _ in 0..<4 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                hosting.view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
                hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
                frames.insert(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
            }
            XCTAssertEqual(frames.count, 1, "controls=\(controls)")
        }
    }

    func testHostedAir75V2EffectsPageLayout() {
        let appearance = SignalAppearance(
            isVisible: true,
            backlight: ZoneAppearance(effect: .viaOff, color: SignalColor(red: 0, green: 149, blue: 255)),
            strip: LocalProfile.default.execution.strip
        )
        let profile = LocalProfile.default.replacingAppearance(appearance, forPreset: .execution)
        let state = KeyphoreAppState(lifecycle: KeyphoreLifecycle(
            health: LayoutHealth(), profiles: LayoutProfile(profile: profile),
            durableStatus: LayoutStatus(), lighting: LayoutLighting(), runtime: LayoutRuntime()
        ))
        let hosting = NSHostingController(rootView: SignalSettingsView(state: state, checkForUpdates: {}))
        let size = NSSize(width: 1040, height: 760)

        XCTAssertEqual(signalSettingsEffects(for: .backlight, model: state.activeKeyboardModel).count, 41)
        attach(hosting.view, size: size, name: "air75-v2-effects")
    }

    func testDisconnectedKeyboardUsesGenericPresentation() {
        let state = KeyphoreAppState(environment: ["KEYPHORE_ACCEPTANCE_FIXTURE": "configured"])
        let popover = KeyphorePopover(state: state)

        XCTAssertTrue(popover.usesGenericKeyboardPresentation)
    }

    func testLocalizedPanelsFitTheirWidthAndAttachPreviews() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        for choice in AppLanguageChoice.allCases where choice != .system {
            var arguments = previous
            arguments["app.language"] = choice.rawValue
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            let state = KeyphoreAppState(environment: ["KEYPHORE_ACCEPTANCE_FIXTURE": "ready-attention"])
            let popover = NSHostingController(rootView: KeyphorePopover(state: state))
            let size = popover.sizeThatFits(in: NSSize(width: 392, height: 0))
            XCTAssertEqual(size.width, 392, accuracy: 1)
            XCTAssertGreaterThanOrEqual(size.height, 350)
            XCTAssertLessThanOrEqual(size.height, 470, "\(choice)")
            attach(popover.view, size: size, name: "\(choice)-panel")
            for tab in [SettingsTab.lights, .general, .about] {
                state.selectedSettingsTab = tab
                let settings = NSHostingController(rootView: SignalSettingsView(state: state, checkForUpdates: {}))
                let fitted = settings.sizeThatFits(in: NSSize(width: 1040, height: 760))
                XCTAssertEqual(fitted.width, 1040, accuracy: 1)
                attach(settings.view, size: NSSize(width: 1040, height: 760), name: "\(choice)-\(tab)")
                if choice == .simplifiedChinese && tab == .lights {
                    for scheme in [ColorScheme.light, .dark] {
                        let themed = NSHostingController(rootView: SignalSettingsView(state: state, checkForUpdates: {})
                            .environment(\.colorScheme, scheme))
                        themed.view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                        attach(themed.view, size: NSSize(width: 1040, height: 760), name: "color-layout-\(scheme)")
                    }
                }
            }
        }
    }

    private func attach(_ view: NSView, size: NSSize, name: String) {
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Could not render \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPopoverMapsEveryAppAppearanceToAColorScheme() {
        XCTAssertNil(AppAppearance.system.preferredColorScheme)
        XCTAssertEqual(AppAppearance.dark.preferredColorScheme, .dark)
        XCTAssertEqual(AppAppearance.light.preferredColorScheme, .light)
    }

    func testMenuBarPanelRetainsKeyboardSpaceUnderCompressedHeightProposal() {
        for fixture in ["ready-execution", "ready-attention", "ready-completion", "configured", "ready-off"] {
            let state = KeyphoreAppState(environment: ["KEYPHORE_ACCEPTANCE_FIXTURE": fixture])
            let hosting = NSHostingController(rootView: KeyphorePopover(state: state))

            let size = hosting.sizeThatFits(in: NSSize(width: 392, height: 0))

            XCTAssertEqual(size.width, 392, accuracy: 1)
            XCTAssertGreaterThanOrEqual(size.height, 350, "The approved panel must reserve its 344 × 132 keyboard even during intrinsic sizing: \(fixture)")
            XCTAssertLessThanOrEqual(size.height, 370, "The approved status-first panel has no management footer: \(fixture)")
        }
    }
}

private struct LayoutHealth: KeyphoreHealthProviding {
    func currentHealth() -> KeyphoreHealth {
        .configured(keyboard: .connected(protocolHealthy: true, model: .air75V2))
    }
}

private struct SelectionLayoutHealth: KeyphoreHealthProviding {
    let model: SupportedKeyboardModel?
    func currentHealth() -> KeyphoreHealth {
        .configured(keyboard: model.map { .connected(protocolHealthy: true, model: $0) } ?? .ambiguous)
    }
}

private struct LayoutProfile: LocalProfileProviding {
    let profile: LocalProfile
    func currentProfile() -> LocalProfile { profile }
}

private struct LayoutStatus: DurableStatusProviding {
    func currentOutcome() -> DurableStatusOutcome { .execution }
}

private final class LayoutLighting: LightingEmitting {
    func emit(_ behavior: LightingBehavior) {}
}

private final class LayoutRuntime: KeyphoreRuntimeManaging {
    func activateQuitGate() {}
    func disableOwnedHooks() {}
    func stopCompanion() {}
    func clearManagedRuntimeState() {}
    func requestSignalOff() {}
    func enableOwnedHooksIfTrusted() -> Bool { true }
    func startCompanion() {}
    func clearQuitGate() {}
}
