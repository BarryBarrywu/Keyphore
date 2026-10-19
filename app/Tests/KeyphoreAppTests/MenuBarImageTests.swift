import AppKit
import XCTest
import KeyphoreCore

final class MenuBarImageTests: XCTestCase {
    func testColorPickerStatePreservesHiddenHueAndSaturationThroughBlackAndGray() {
        var state = SignalColorPickerState(SignalColor(red: 0, green: 0, blue: 255))

        state.synchronize(with: SignalColor(red: 0, green: 0, blue: 0))
        state.update(hue: 1.0 / 3.0, saturation: 0.5)
        XCTAssertEqual(state.color, SignalColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(state.update(brightness: 1), SignalColor(red: 128, green: 255, blue: 128))

        state.synchronize(with: SignalColor(red: 128, green: 128, blue: 128))
        state.update(hue: 5.0 / 6.0)
        XCTAssertEqual(state.update(saturation: 1), SignalColor(red: 128, green: 0, blue: 128))
    }

    func testColorPickerStateSynchronizesOrdinaryExternalRGBChanges() {
        var state = SignalColorPickerState(SignalColor(red: 0, green: 0, blue: 255))
        let external = SignalColor(red: 18, green: 171, blue: 240)

        state.synchronize(with: external)

        XCTAssertEqual(state.color, external)

        state.update(hue: 1)
        state.synchronize(with: state.color)
        XCTAssertEqual(state.hue, 1)
    }

    func testOfficialPaletteAndNativeColorTextFormatsPreserveExactRGBBytes() throws {
        XCTAssertEqual(SignalPalette.colors.map { SignalColorTextCodec.format($0, as: .hex) }, [
            "#FF6D1E", "#FFF200", "#00FFAE", "#0095FF", "#8787F8", "#FF3B96",
            "#FC1616", "#FFBF00", "#0FE8FB", "#22FF22", "#2222FF", "#FF4BFF",
        ])
        let color = SignalColor(red: 0x12, green: 0xAB, blue: 0xF0)
        XCTAssertEqual(SignalColorTextCodec.parse("#12ABF0", format: .hex), color)
        XCTAssertEqual(SignalColorTextCodec.parse("1af", format: .hex), SignalColor(red: 0x11, green: 0xAA, blue: 0xFF))
        XCTAssertEqual(SignalColorTextCodec.parse("rgb(18, 171, 240)", format: .rgb), color)
        XCTAssertEqual(SignalColorTextCodec.format(color, as: .rgb), "rgb(18, 171, 240)")
        XCTAssertNil(SignalColorTextCodec.parse("rgb(256, 0, 0)", format: .rgb))
    }

    func testRecentColorsAreUniqueNewestFirstAndCappedAtTwelve() throws {
        let suite = "keyphore-color-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for value in 0..<14 {
            _ = RecentSignalColors.record(SignalColor(red: UInt8(value), green: 0, blue: 0), in: defaults)
        }
        _ = RecentSignalColors.record(SignalColor(red: 5, green: 0, blue: 0), in: defaults)
        let restored = RecentSignalColors.load(from: defaults)
        XCTAssertEqual(restored.count, 12)
        XCTAssertEqual(restored.first, SignalColor(red: 5, green: 0, blue: 0))
        XCTAssertEqual(Set(restored.map { $0.red }).count, 12)
    }

    func testKeyboardShowsTheLiveSignalAndConfiguredAppearance() {
        let appearance = SignalAppearance(
            isVisible: true,
            backlight: ZoneAppearance(
                effect: .backlightStatic, color: SignalColor(red: 170, green: 80, blue: 40),
                brightness: SignalBrightness(percent: 35)!
            ),
            strip: LocalProfile.default.execution.strip
        )
        let profile = LocalProfile.default.replacingAppearance(appearance, for: .execution)
        let presentation = KeyboardSignalPresentation(
            snapshot: snapshot(profile: profile), preview: nil
        )
        XCTAssertEqual(presentation.signal, .execution)
        XCTAssertEqual(presentation.appearance, appearance)
        XCTAssertTrue(presentation.isLit)
        XCTAssertFalse(presentation.isPreviewing)
    }

    func testKeyboardUsesThePreviewStageIncludingItsUnlitPhase() throws {
        var preview = try previewRecord()
        preview.phase = .presenting
        preview.currentPreset = .attention
        preview.presentationIsLit = true
        let lit = KeyboardSignalPresentation(snapshot: snapshot(), preview: preview)
        XCTAssertEqual(lit.signal, .attention)
        XCTAssertEqual(lit.appearance, LocalProfile.default.attention)
        XCTAssertTrue(lit.isLit)
        XCTAssertTrue(lit.isPreviewing)

        preview.presentationIsLit = false
        let unlit = KeyboardSignalPresentation(snapshot: snapshot(), preview: preview)
        XCTAssertEqual(unlit.signal, .attention)
        XCTAssertFalse(unlit.isLit)
    }

    func testPendingPreviewDoesNotInventAnActiveStage() throws {
        let presentation = KeyboardSignalPresentation(
            snapshot: snapshot(), preview: try previewRecord()
        )
        XCTAssertEqual(presentation.signal, .signalOff)
        XCTAssertFalse(presentation.isLit)
        XCTAssertTrue(presentation.isPreviewing)
    }

    func testFinishedPreviewReturnsToAggregateControl() throws {
        for phase in [
            SignalPreviewPhase.awaitingVisualConfirmation, .confirmed, .rejected, .failed,
        ] {
            var preview = try previewRecord()
            preview.phase = phase
            preview.currentPreset = .completion
            let presentation = KeyboardSignalPresentation(snapshot: snapshot(), preview: preview)
            XCTAssertEqual(presentation.signal, .execution)
            XCTAssertTrue(presentation.isLit)
            XCTAssertFalse(presentation.isPreviewing)
        }
    }

    func testDisconnectedAndHiddenSignalsDoNotIlluminateTheKeyboard() {
        XCTAssertFalse(KeyboardSignalPresentation(
            snapshot: snapshot(ready: false), preview: nil
        ).isLit)
        let hidden = SignalAppearance(
            isVisible: false, backlight: LocalProfile.default.execution.backlight,
            strip: LocalProfile.default.execution.strip
        )
        XCTAssertFalse(KeyboardSignalPresentation(
            snapshot: snapshot(profile: LocalProfile.default.replacingAppearance(hidden, for: .execution)),
            preview: nil
        ).isLit)
    }

    func testIdleKeepsNoTaskStatusWhileFollowingTheConfiguredIdleAppearance() {
        let idle = SignalAppearance(
            isVisible: true, backlight: LocalProfile.defaultIdle.backlight,
            strip: LocalProfile.defaultIdle.strip
        )
        let profile = LocalProfile.default.replacingAppearance(idle, forPreset: .idle)
        let presentation = KeyboardSignalPresentation(
            snapshot: snapshot(signal: .signalOff, profile: profile), preview: nil
        )

        XCTAssertEqual(presentation.signal, .signalOff)
        XCTAssertEqual(presentation.appearance, idle)
        XCTAssertTrue(presentation.isLit)
        XCTAssertEqual(
            AggregateSignal.signalOff.presentation(in: profile).menuBarAccessibilityLabel,
            "\(AppCopy.value(.productName)), \(AppCopy.value(.settingsIdle))"
        )
    }

    private func snapshot(
        ready: Bool = true, signal: AggregateSignal = .execution, profile: LocalProfile = .default
    ) -> LifecycleSnapshot {
        LifecycleSnapshot(
            health: .configured(keyboard: ready ? .connected(protocolHealthy: true) : .disconnected),
            menuState: ready ? .ready : .configured,
            durableStatus: .execution,
            currentSignal: signal,
            profile: profile
        )
    }

    private func previewRecord() throws -> SignalPreviewRecord {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try SignalPreviewStore(url: directory.appendingPathComponent("preview.json")).begin()
    }

    func testEverySignalUsesSystemAdaptiveMenuBarRendering() {
        for signal in [
            AggregateSignal.signalOff,
            .execution,
            .attention,
            .completion,
        ] {
            XCTAssertTrue(
                signal.presentation(in: .default).menuBarImage.isTemplate,
                "\(signal) must remain visible on every menu bar background"
            )
        }
    }

    func testMenuBarIconsHaveAStableEighteenPointFootprint() {
        for signal in [AggregateSignal.signalOff, .execution, .attention, .completion] {
            XCTAssertEqual(
                signal.presentation(in: .default).menuBarImage.size,
                NSSize(width: 18, height: 18),
                "Changing signal must not move neighboring menu bar items"
            )
        }
    }

    func testEverySignalKeepsTheApprovedKeycapFrameAndBottomLight() throws {
        for signal in [AggregateSignal.signalOff, .execution, .attention, .completion] {
            let bitmap = try rendered(signal.presentation(in: .default).menuBarImage)
            for point in [NSPoint(x: 1.5, y: 9), NSPoint(x: 16.5, y: 9),
                          NSPoint(x: 9, y: 1.5), NSPoint(x: 9, y: 16.5),
                          NSPoint(x: 9, y: 13.5)] {
                XCTAssertGreaterThan(
                    try alpha(bitmap, at: point), 0.9,
                    "\(signal) must keep the B design's frame and bottom light"
                )
            }
            XCTAssertEqual(try alpha(bitmap, at: .zero), 0)
        }
    }

    func testMenuBarImagesDescribeTheAppAndCurrentSignal() {
        let cases: [(AggregateSignal, AppCopyKey)] = [
            (.signalOff, .signalOff), (.execution, .execution),
            (.attention, .attention), (.completion, .completion),
        ]
        for (signal, key) in cases {
            let description = signal.presentation(in: .default).menuBarImage.accessibilityDescription
            XCTAssertEqual(description, "\(AppCopy.value(.productName)), \(AppCopy.value(key))")
        }
    }

    func testKeycapFacesDistinguishPlayAttentionCompletionAndSignalOff() throws {
        let cases: [(AggregateSignal, [NSPoint], NSPoint)] = [
            (.execution, [NSPoint(x: 8, y: 7), NSPoint(x: 10.5, y: 7)], NSPoint(x: 5.5, y: 6.5)),
            (.attention, [NSPoint(x: 9, y: 5.5), NSPoint(x: 9, y: 10)], NSPoint(x: 7.5, y: 7)),
            (.completion, [NSPoint(x: 6.5, y: 8.5), NSPoint(x: 11, y: 6.5)], NSPoint(x: 9, y: 5.5)),
        ]
        let signalOff = try rendered(AggregateSignal.signalOff.presentation(in: .default).menuBarImage)
        for (signal, ink, blank) in cases {
            let bitmap = try rendered(signal.presentation(in: .default).menuBarImage)
            for point in ink {
                XCTAssertGreaterThan(try alpha(bitmap, at: point), 0.9, "\(signal)")
                XCTAssertEqual(try alpha(signalOff, at: point), 0)
            }
            XCTAssertEqual(try alpha(bitmap, at: blank), 0, "\(signal)")
        }
    }

    private func rendered(_ image: NSImage) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
        return bitmap
    }

    private func alpha(_ bitmap: NSBitmapImageRep, at point: NSPoint) throws -> CGFloat {
        try XCTUnwrap(bitmap.colorAt(x: Int(point.x * 4), y: Int(point.y * 4))).alphaComponent
    }
}
