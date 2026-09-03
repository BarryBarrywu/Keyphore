import AppKit
import XCTest
import KeyphoreCore

final class MenuBarImageTests: XCTestCase {
    func testKeyboardShowsTheLiveSignalAndConfiguredAppearance() {
        let appearance = SignalAppearance(
            isVisible: true,
            color: SignalColor(red: 170, green: 80, blue: 40),
            brightness: SignalBrightness(percent: 35)!,
            pattern: .slowFlashing
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
        preview.currentSignal = .attention
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
            preview.currentSignal = .completion
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
            isVisible: false, color: LocalProfile.default.execution.color,
            brightness: .full, pattern: .steady
        )
        XCTAssertFalse(KeyboardSignalPresentation(
            snapshot: snapshot(profile: LocalProfile.default.replacingAppearance(hidden, for: .execution)),
            preview: nil
        ).isLit)
    }

    private func snapshot(ready: Bool = true, profile: LocalProfile = .default) -> LifecycleSnapshot {
        LifecycleSnapshot(
            health: .configured(keyboard: ready ? .connected(protocolHealthy: true) : .disconnected),
            menuState: ready ? .ready : .configured,
            durableStatus: .execution,
            currentSignal: .execution,
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
