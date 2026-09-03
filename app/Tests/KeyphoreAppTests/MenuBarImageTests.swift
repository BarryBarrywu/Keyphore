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
}
