import Foundation
import KeyphoreCore
import XCTest

final class SignalPreviewAcceptanceTests: XCTestCase {
    func testVIAChannelIsolationSurvivesPersistenceWithoutClaimingSideLightReadback() throws {
        let fixture = try NativeLightingFixture()
        fixture.lighting.protection = .untouchedProtocolChannel
        let controller = SignalPreviewController(store: fixture.preview, lighting: fixture.lighting)
        _ = try fixture.preview.begin(at: .milliseconds(0))
        _ = try controller.poll(at: .milliseconds(0), profile: .default)
        let record = try XCTUnwrap(SignalPreviewStore(url: fixture.preview.url).load())
        XCTAssertTrue(record.protocolReadbackSucceeded)
        XCTAssertTrue(record.unmanagedZonesPreserved)
        XCTAssertEqual(record.unmanagedZoneProtection, .untouchedProtocolChannel)
        let report = DiagnosticReport(snapshot: DiagnosticSnapshot(
            appVersion: "test", macOSVersion: "test", codexHosts: [], integration: .notConfigured,
            keyboard: .connected(protocolHealthy: true, model: .air75V2)
        ), language: .english, preview: record)
        let fields = try XCTUnwrap(report.preview)
        XCTAssertTrue(fields.contains {
            $0.contains(AppCopy.value(.diagnosticChannelIsolation, language: .english))
        })
        XCTAssertFalse(fields.contains {
            $0 == "\(AppCopy.value(.diagnosticPreviewRhythm, language: .english)): \(AppCopy.value(.diagnosticHealthy, language: .english))"
        })
        fixture.lighting.protection = .readback
        let started = try XCTUnwrap(record.stageStartedAt)
        _ = try controller.poll(at: .milliseconds(started.millisecondsSince1970 + 6_000), profile: .default)
        XCTAssertEqual(try fixture.preview.load()?.unmanagedZoneProtection, .untouchedProtocolChannel)
    }

    func testSelectedSignalStartsDirectlyHoldsSixSecondsAndRestoresLatestAggregate() throws {
        for signal in [LightingPreset.attention, .completion] {
            let fixture = try NativeLightingFixture()
            try fixture.signal(.execution)
            let companion = fixture.companion()
            _ = try fixture.preview.begin(preset: signal, at: .milliseconds(0))
            try companion.sync(at: .milliseconds(0))
            XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.appearance(forPreset: signal))])
            let started = try XCTUnwrap(fixture.preview.load()?.stageStartedAt).millisecondsSince1970
            try fixture.signal(.completion)
            try companion.sync(at: .milliseconds(started + 5_999))
            XCTAssertEqual(try fixture.preview.load()?.currentPreset, signal)
            try companion.sync(at: .milliseconds(started + 6_000))
            let record = try XCTUnwrap(fixture.preview.load())
            XCTAssertEqual(record.phase, .completed)
            XCTAssertEqual(record.completedPresets, [signal])
            XCTAssertEqual(record.visualConfirmation, .notRequested)
            XCTAssertEqual(fixture.lighting.behaviors.last, .signal(LocalProfile.default.completion))
            XCTAssertThrowsError(try fixture.preview.recordVisualConfirmation(.confirmed))
        }
    }

    func testIdlePreviewUsesOffOrCustomAndReturnsToLatestTaskAfterSixSeconds() throws {
        for visible in [false, true] {
            let idle = testSignalAppearance(color: SignalColor(red: 12, green: 34, blue: 56), isVisible: visible)
            let profile = LocalProfile.default.replacingAppearance(idle, forPreset: .idle).replacingControlledZones(.strip)
            let fixture = try NativeLightingFixture(profile: profile)
            try fixture.signal(.execution)
            let companion = fixture.companion()
            _ = try fixture.preview.begin(preset: .idle, at: .milliseconds(0))
            try companion.sync(at: .milliseconds(0))
            XCTAssertEqual(fixture.lighting.behaviors.last, .signal(idle, controlledZones: .strip))
            let started = try XCTUnwrap(fixture.preview.load()?.stageStartedAt).millisecondsSince1970
            try fixture.signal(.attention)
            try companion.sync(at: .milliseconds(started + 5_999))
            XCTAssertEqual(try fixture.preview.load()?.currentPreset, .idle)
            try companion.sync(at: .milliseconds(started + 6_000))
            XCTAssertEqual(try fixture.preview.load()?.phase, .completed)
            XCTAssertEqual(try fixture.preview.load()?.completedPresets, [.idle])
            XCTAssertEqual(fixture.lighting.behaviors.last, .signal(profile.attention, controlledZones: .strip))
            XCTAssertThrowsError(try fixture.preview.recordVisualConfirmation(.confirmed))
        }
    }

    func testTaskPreviewEndsAtLatestIdleAfterCompletionExpires() throws {
        let fixture = try NativeLightingFixture()
        let companion = fixture.companion()
        try fixture.signal(.completion)
        _ = try fixture.preview.begin(preset: .attention, at: .milliseconds(99_000))
        try companion.sync(at: .milliseconds(99_000))
        let idle = testSignalAppearance(color: SignalColor(red: 12, green: 34, blue: 56))
        try fixture.profiles.save(LocalProfile.default.replacingAppearance(idle, forPreset: .idle))
        let started = try XCTUnwrap(fixture.preview.load()?.stageStartedAt).millisecondsSince1970
        try companion.sync(at: .milliseconds(started + 6_000))
        XCTAssertEqual(try fixture.preview.load()?.phase, .completed)
        XCTAssertEqual(fixture.lighting.behaviors.last, .signal(idle))
        XCTAssertTrue(try fixture.status.load().owners.isEmpty)
    }

    func testNewSelectionMadeDuringApplyCannotBeOverwrittenByOldSuccessOrFailure() throws {
        for oldApplyFails in [false, true] {
            let fixture = try NativeLightingFixture()
            let companion = fixture.companion()
            let original = try fixture.preview.begin(preset: .attention, at: .milliseconds(0))
            var replacement: SignalPreviewRecord?
            fixture.lighting.willApply = { _ in
                guard replacement == nil else { return }
                replacement = try SignalPreviewStore(url: fixture.preview.url).begin(preset: .completion, at: .milliseconds(100))
                if oldApplyFails { throw SystemAir65HIDError.deviceDisappeared }
            }
            try companion.sync(at: .milliseconds(0))
            let newest = try XCTUnwrap(replacement)
            XCTAssertNotEqual(newest.id, original.id)
            XCTAssertEqual(try fixture.preview.load(), newest)
            XCTAssertEqual(newest.phase, .pending)
            fixture.lighting.willApply = { _ in }
            try companion.sync(at: .milliseconds(200))
            XCTAssertEqual(try fixture.preview.load()?.id, newest.id)
            XCTAssertEqual(try fixture.preview.load()?.currentPreset, .completion)
            XCTAssertEqual(fixture.lighting.behaviors.last, .signal(LocalProfile.default.completion))
            XCTAssertFalse(fixture.lighting.behaviors.contains(.off), "An old failure must not restore aggregate over a newer request")
        }
    }

    func testEditingSelectedProfileRestartsTheSingleSignalHold() throws {
        let fixture = try NativeLightingFixture()
        let companion = fixture.companion()
        _ = try fixture.preview.begin(preset: .completion, at: .milliseconds(0))
        try companion.sync(at: .milliseconds(0))
        let changed = LocalProfile.default.completion.replacingAppearance(
            ZoneAppearance(effect: .backlightStatic, color: SignalColor(red: 12, green: 34, blue: 56)), for: .backlight)
        try fixture.profiles.save(LocalProfile.default.replacingAppearance(changed, for: .completion))
        try companion.sync(at: .milliseconds(5_000))
        let started = try XCTUnwrap(fixture.preview.load()?.stageStartedAt).millisecondsSince1970
        XCTAssertEqual(fixture.lighting.behaviors.last, .signal(changed))
        try companion.sync(at: .milliseconds(started + 5_999))
        XCTAssertEqual(try fixture.preview.load()?.phase, .presenting)
        try companion.sync(at: .milliseconds(started + 6_000))
        XCTAssertEqual(try fixture.preview.load()?.phase, .completed)
        XCTAssertEqual(fixture.lighting.behaviors.last, .off)
    }

    func testQuitCancelsSingleSignalPreviewAndAcknowledgesOnlyOwnedZonesOff() throws {
        let fixture = try NativeLightingFixture(profile: LocalProfile.default.replacingControlledZones(.strip))
        let companion = fixture.companion()
        _ = try fixture.preview.begin(preset: .attention, at: .milliseconds(0))
        try companion.sync(at: .milliseconds(0))
        try fixture.quit.activate()
        try companion.sync(at: .milliseconds(100))
        XCTAssertEqual(try fixture.preview.load()?.phase, .failed)
        XCTAssertEqual(fixture.lighting.behaviors.last, .off(for: .strip))
        XCTAssertTrue(fixture.acknowledgement.isAcknowledged)
        XCTAssertEqual(try fixture.ownership.load().zones, [])
    }

    func testNativePreviewHoldsEffectsWithoutRewritingFramesAndRestoresCurrentAggregate() throws {
        let fixture = try NativeLightingFixture(profile: LocalProfile.default.replacingControlledZones(.both))
        try fixture.signal(.attention)
        let companion = fixture.companion()
        _ = try fixture.preview.begin(at: .milliseconds(0))
        try companion.sync(at: .milliseconds(0))
        let checkpoint = try Data(contentsOf: fixture.preview.url)
        for time in stride(from: UInt64(100), through: 5_900, by: 100) {
            try companion.sync(at: .milliseconds(time))
            XCTAssertEqual(try Data(contentsOf: fixture.preview.url), checkpoint)
            XCTAssertEqual(fixture.health.load(at: .milliseconds(time)), .connected(protocolHealthy: true, model: .air75V3))
        }
        XCTAssertEqual(fixture.lighting.behaviors.count, 1)
        for time: UInt64 in [6_000, 12_000, 14_000] { try companion.sync(at: .milliseconds(time)) }
        let record = try XCTUnwrap(fixture.preview.load())
        XCTAssertEqual(record.phase, .awaitingVisualConfirmation)
        XCTAssertEqual(record.completedPresets, [.execution, .attention, .completion])
        XCTAssertTrue(record.protocolReadbackSucceeded)
        XCTAssertTrue(record.unmanagedZonesPreserved)
        XCTAssertEqual(fixture.lighting.behaviors.last, .signal(LocalProfile.default.attention, controlledZones: .both))
        try fixture.preview.recordVisualConfirmation(.confirmed)
        XCTAssertEqual(try fixture.preview.load()?.phase, .confirmed)
    }

    func testSlowApplyDoesNotConsumeVisibleNativeHoldTime() throws {
        let fixture = try NativeLightingFixture()
        var clock = ContinuousClock.now
        fixture.lighting.didApply = { clock = clock.advanced(by: .milliseconds(2_500)) }
        let controller = SignalPreviewController(store: fixture.preview,
                                                lighting: fixture.lighting, clock: { clock })
        _ = try fixture.preview.begin(at: .milliseconds(0))
        _ = try controller.poll(at: .milliseconds(0), profile: .default)
        _ = try controller.poll(at: .milliseconds(8_499), profile: .default)
        XCTAssertEqual(fixture.lighting.behaviors.count, 1)
        _ = try controller.poll(at: .milliseconds(8_500), profile: .default)
        XCTAssertEqual(try fixture.preview.load()?.currentPreset, .attention)
        fixture.lighting.didApply = {}
    }

    func testNativeReadbackFailureEndsPreviewAndRestoresLatestAggregate() throws {
        let fixture = try NativeLightingFixture()
        let companion = fixture.companion()
        _ = try fixture.preview.begin(at: .milliseconds(0))
        try companion.sync(at: .milliseconds(0))
        try fixture.signal(.attention)
        fixture.lighting.displaysExpected = false
        try companion.sync(at: .milliseconds(1_000))
        XCTAssertEqual(try fixture.preview.load()?.phase, .failed)
        XCTAssertFalse(try XCTUnwrap(fixture.preview.load()).protocolReadbackSucceeded)
        XCTAssertEqual(fixture.lighting.behaviors.last, .signal(LocalProfile.default.attention))
    }

    func testUnmanagedZoneEvidenceFailureFailsPresentation() throws {
        let fixture = try NativeLightingFixture()
        fixture.lighting.preserved = false
        let controller = SignalPreviewController(store: fixture.preview, lighting: fixture.lighting)
        _ = try fixture.preview.begin(at: .milliseconds(0))
        XCTAssertEqual(try controller.poll(at: .milliseconds(0), profile: .default), .finished)
        XCTAssertEqual(try fixture.preview.load()?.phase, .failed)
        XCTAssertEqual(try fixture.preview.load()?.unmanagedZonesPreserved, false)
    }

    func testQuitCancelsNativePreviewAndDoesNotReplayItAfterReopen() throws {
        let fixture = try NativeLightingFixture(profile: LocalProfile.default.replacingControlledZones(.strip))
        let companion = fixture.companion()
        _ = try fixture.preview.begin(at: .milliseconds(0))
        try companion.sync(at: .milliseconds(0))
        try fixture.quit.activate()
        try companion.sync(at: .milliseconds(100))
        XCTAssertEqual(fixture.lighting.behaviors.last, .off(for: .strip))
        XCTAssertTrue(fixture.acknowledgement.isAcknowledged)
        XCTAssertEqual(try fixture.preview.load()?.phase, .failed)
        try fixture.quit.clear()
        try companion.sync(at: .milliseconds(200))
        XCTAssertEqual(fixture.lighting.behaviors.count, 3)
        XCTAssertEqual(fixture.lighting.behaviors.last, .off(for: .strip))
    }

    func testFailedPreviewCheckpointCannotLeaveStaleOffCache() throws {
        let fixture = try NativeLightingFixture()
        let companion = fixture.companion()
        try companion.sync(at: .milliseconds(0))
        _ = try fixture.preview.begin(at: .milliseconds(1))
        fixture.lighting.didApply = {
            try! FileManager.default.removeItem(at: fixture.preview.url)
            try! FileManager.default.createDirectory(at: fixture.preview.url, withIntermediateDirectories: false)
        }
        XCTAssertThrowsError(try companion.sync(at: .milliseconds(100)))
        fixture.lighting.didApply = {}
        try fixture.quit.activate()
        try companion.sync(at: .milliseconds(200))
        XCTAssertEqual(fixture.lighting.behaviors, [.off, .signal(LocalProfile.default.execution), .off])
        XCTAssertTrue(fixture.acknowledgement.isAcknowledged)
    }
}
