import Foundation
import KeyphoreCore
import XCTest

final class SignalPreviewAcceptanceTests: XCTestCase {
    func testDelayedPollingCannotSkipOrShortenTheUnlitPreviewPhase() throws {
        let fixture = try PreviewFixture()
        _ = try fixture.store.begin(at: .milliseconds(0))

        _ = try fixture.controller.poll(at: .milliseconds(0))
        _ = try fixture.controller.poll(at: .milliseconds(2_100))

        XCTAssertEqual(fixture.lighting.behaviors, [
            .signal(fixture.steady(fixture.profile.execution)), .off,
        ])
        XCTAssertEqual(try fixture.store.load()?.currentSignal, .execution)

        _ = try fixture.controller.poll(at: .milliseconds(3_099))
        XCTAssertEqual(fixture.lighting.behaviors.last, .off)
        XCTAssertEqual(try fixture.store.load()?.currentSignal, .execution)
    }

    func testHardwareLatencyDoesNotConsumeTheLitOrUnlitHoldTime() throws {
        let fixture = try PreviewFixture()
        fixture.lighting.didApply = {
            fixture.clock.now = fixture.clock.now.advanced(by: .milliseconds(2_500))
        }
        _ = try fixture.store.begin(at: .milliseconds(0))

        for time: UInt64 in [0, 2_600, 3_499] {
            _ = try fixture.controller.poll(at: .milliseconds(time))
        }
        XCTAssertEqual(fixture.lighting.behaviors, [.signal(fixture.steady(fixture.profile.execution))])

        _ = try fixture.controller.poll(at: .milliseconds(3_500))
        _ = try fixture.controller.poll(at: .milliseconds(6_999))
        XCTAssertEqual(fixture.lighting.behaviors, [
            .signal(fixture.steady(fixture.profile.execution)), .off,
        ])

        _ = try fixture.controller.poll(at: .milliseconds(7_000))
        XCTAssertEqual(fixture.lighting.behaviors, [
            .signal(fixture.steady(fixture.profile.execution)), .off,
            .signal(fixture.steady(fixture.profile.execution)),
        ])
        fixture.lighting.didApply = {}
    }

    func testPreviewStartsOnlyAfterAnExplicitRequestAndUsesAControllableClock() throws {
        let fixture = try PreviewFixture()

        XCTAssertEqual(try fixture.controller.poll(at: .milliseconds(0)), .inactive)
        XCTAssertTrue(fixture.lighting.behaviors.isEmpty)

        _ = try fixture.store.begin(at: .milliseconds(0))
        for time: UInt64 in stride(from: 0, through: 9_000, by: 1_000) {
            XCTAssertEqual(try fixture.controller.poll(at: .milliseconds(time)), .active)
        }
        XCTAssertEqual(try fixture.controller.poll(at: .milliseconds(10_000)), .finished)

        XCTAssertEqual(fixture.lighting.behaviors, [
            .signal(fixture.steady(fixture.profile.execution)),
            .off,
            .signal(fixture.steady(fixture.profile.execution)),
            .off,
            .signal(fixture.profile.attention),
            .signal(fixture.steady(fixture.profile.completion)),
            .off,
            .signal(fixture.steady(fixture.profile.completion)),
            .off,
        ])
        let record = try XCTUnwrap(fixture.store.load())
        XCTAssertEqual(record.phase, .awaitingVisualConfirmation)
        XCTAssertEqual(record.completedSignals, [.execution, .attention, .completion])
        XCTAssertTrue(record.protocolReadbackSucceeded)
        XCTAssertTrue(record.rhythmLightPreserved)
        XCTAssertEqual(record.visualConfirmation, .notRequested)
    }

    func testVisualConfirmationIsRecordedSeparatelyFromProtocolEvidence() throws {
        let fixture = try PreviewFixture()
        _ = try fixture.store.begin(at: .milliseconds(0))
        for time: UInt64 in stride(from: 0, through: 10_000, by: 1_000) {
            _ = try fixture.controller.poll(at: .milliseconds(time))
        }

        try fixture.store.recordVisualConfirmation(.confirmed)

        let record = try XCTUnwrap(fixture.store.load())
        XCTAssertEqual(record.phase, .confirmed)
        XCTAssertTrue(record.protocolReadbackSucceeded)
        XCTAssertEqual(record.visualConfirmation, .confirmed)
    }

    func testHiddenSignalIsPresentedAsOffDuringItsPreviewStage() throws {
        let fixture = try PreviewFixture(executionVisible: false)
        _ = try fixture.store.begin(at: .milliseconds(0))

        _ = try fixture.controller.poll(at: .milliseconds(0))

        XCTAssertEqual(fixture.lighting.behaviors, [.off])
    }

    func testFailedReadbackDoesNotPersistSuccessfulProtocolOrRhythmEvidence() throws {
        let fixture = try PreviewFixture()
        fixture.lighting.error = NuPhyIOAdapterError.mainBacklightReadbackMismatch
        _ = try fixture.store.begin(at: .milliseconds(0))

        XCTAssertEqual(try fixture.controller.poll(at: .milliseconds(0)), .finished)

        let record = try XCTUnwrap(fixture.store.load())
        XCTAssertEqual(record.phase, .failed)
        XCTAssertFalse(record.protocolReadbackSucceeded)
        XCTAssertFalse(record.rhythmLightPreserved)
    }

    func testCompanionRestoresTheCurrentAggregateAfterPreviewFinishes() throws {
        let fixture = try PreviewFixture()
        try fixture.statusStore.recordSignal(
            ownerID: SignalOwnerID(product: "codex", sessionID: "session", agentID: "main"),
            turnID: "turn",
            signal: .attention,
            expiresAt: .milliseconds(100_000),
            replacingSession: true,
            lockBudget: .milliseconds(100)
        )
        let companion = KeyphoreCompanion(
            store: fixture.statusStore,
            profileProvider: { fixture.profile },
            lighting: fixture.lighting,
            previewStore: fixture.store
        )
        _ = try fixture.store.begin(at: .milliseconds(0))

        for time: UInt64 in stride(from: 0, through: 20_000, by: 2_000) {
            try companion.sync(at: .milliseconds(time))
        }

        XCTAssertEqual(fixture.lighting.behaviors.last, .signal(fixture.profile.attention))
        XCTAssertEqual(try fixture.store.load()?.phase, .awaitingVisualConfirmation)
    }

    func testHealthCheckCannotInterruptAnActivePreview() throws {
        let fixture = try PreviewFixture()
        let companion = KeyphoreCompanion(
            store: fixture.statusStore,
            profileProvider: { fixture.profile },
            lighting: fixture.lighting,
            previewStore: fixture.store
        )
        _ = try fixture.store.begin(at: .milliseconds(0))
        try companion.sync(at: .milliseconds(0))

        try companion.healthCheck(at: .milliseconds(1_000))

        XCTAssertEqual(fixture.lighting.displayChecks, 0)
        XCTAssertEqual(fixture.lighting.behaviors, [.signal(fixture.steady(fixture.profile.execution))])
    }

    func testMalformedPreviewStateCannotBlockNormalCompanionOperation() throws {
        let fixture = try PreviewFixture()
        try Data("not-json".utf8).write(to: fixture.store.url)
        try fixture.statusStore.recordSignal(
            ownerID: SignalOwnerID(product: "codex", sessionID: "session", agentID: "main"),
            turnID: "turn",
            signal: .attention,
            expiresAt: .milliseconds(100_000),
            replacingSession: true,
            lockBudget: .milliseconds(100)
        )
        let companion = KeyphoreCompanion(
            store: fixture.statusStore,
            profileProvider: { fixture.profile },
            lighting: fixture.lighting,
            previewStore: fixture.store
        )

        try companion.sync(at: .milliseconds(0))

        XCTAssertEqual(fixture.lighting.behaviors, [.signal(fixture.profile.attention)])
    }
}

private final class PreviewFixture {
    let directory: URL
    let store: SignalPreviewStore
    let statusStore: DurableStatusStore
    let profile: LocalProfile
    let lighting = PreviewLightingAdapter()
    let clock = PreviewClock()
    let controller: SignalPreviewController

    init(executionVisible: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SignalPreviewStore(url: directory.appending(path: "preview.json"))
        statusStore = DurableStatusStore(url: directory.appending(path: "status.json"))
        let defaults = LocalProfile.default
        profile = LocalProfile(
            execution: Self.patterned(
                defaults.execution,
                .slowFlashing,
                isVisible: executionVisible
            ),
            attention: defaults.attention,
            completion: Self.patterned(defaults.completion, .slowFlashing),
            completionDisplayDuration: defaults.completionDisplayDuration
        )
        controller = SignalPreviewController(
            store: store,
            profileProvider: { [profile] in profile },
            lighting: lighting,
            clock: { [clock] in clock.now }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func steady(_ appearance: SignalAppearance) -> SignalAppearance {
        Self.patterned(appearance, .steady)
    }

    private static func patterned(
        _ appearance: SignalAppearance,
        _ pattern: SignalPattern,
        isVisible: Bool? = nil
    ) -> SignalAppearance {
        SignalAppearance(
            isVisible: isVisible ?? appearance.isVisible,
            color: appearance.color,
            brightness: appearance.brightness,
            pattern: pattern
        )
    }
}

private final class PreviewClock {
    var now = ContinuousClock.now
}

private final class PreviewLightingAdapter: CompanionLightingApplying,
    CompanionLightingEvidenceApplying, CompanionLightingVerifying
{
    private(set) var behaviors: [LightingBehavior] = []
    private(set) var displayChecks = 0
    var error: Error?
    var didApply: () -> Void = {}

    func apply(_ behavior: LightingBehavior) throws {
        _ = try applyAndVerify(behavior)
    }

    func applyAndVerify(_ behavior: LightingBehavior) throws -> NuPhyIOEvidence {
        if let error { throw error }
        behaviors.append(behavior)
        didApply()
        return NuPhyIOEvidence(
            protocolReadbackSucceeded: true,
            visualConfirmation: .notRequested,
            mainState: [],
            rhythmBefore: [1, 2, 3],
            rhythmAfter: [1, 2, 3]
        )
    }

    func displays(_ behavior: LightingBehavior) throws -> Bool {
        displayChecks += 1
        return false
    }
}
