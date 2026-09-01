import Foundation
import KeyphoreCore
import XCTest

@MainActor
final class TransportLifecycleAcceptanceTests: XCTestCase {
    func testConfiguredBecomesReadyOnlyAfterCompanionProtocolReadback() throws {
        let fixture = try TransportFixture()
        let lighting = VerifiedLightingBoundary()
        let companion = KeyphoreCompanion(
            store: fixture.statusStore,
            profile: .default,
            lighting: lighting,
            keyboardHealthStore: fixture.healthStore
        )

        XCTAssertEqual(fixture.healthStore.load(at: .milliseconds(0)), .disconnected)

        try companion.sync(at: .milliseconds(100))
        let lifecycle = KeyphoreLifecycle(
            health: PersistedHealthProvider(store: fixture.healthStore, now: .milliseconds(100)),
            profiles: FixedTransportProfileProvider(),
            durableStatus: FixedTransportStatusProvider(),
            lighting: RecordingTransportMenuLighting(),
            runtime: EmptyTransportRuntime()
        )

        XCTAssertEqual(lighting.behaviors, [.off])
        XCTAssertEqual(lifecycle.refresh().menuState, .ready)
    }

    func testProtocolFailureRemainsConfiguredAndDoesNotBecomeReady() throws {
        let fixture = try TransportFixture()
        let lighting = FailingLightingBoundary(error: Air65DeviceSelectionError.unsupported)
        let companion = KeyphoreCompanion(
            store: fixture.statusStore,
            profile: .default,
            lighting: lighting,
            keyboardHealthStore: fixture.healthStore
        )

        XCTAssertThrowsError(try companion.sync(at: .milliseconds(100)))

        XCTAssertEqual(
            fixture.healthStore.load(at: .milliseconds(100)),
            .connected(protocolHealthy: false)
        )
    }

    func testHealthCheckReappliesAggregateAfterReadbackNoLongerMatches() throws {
        let fixture = try TransportFixture()
        try fixture.statusStore.recordSignal(
            ownerID: SignalOwnerID(product: "codex", sessionID: "session", agentID: "main"),
            turnID: "turn",
            signal: .execution,
            expiresAt: .milliseconds(3_600_000),
            replacingSession: true,
            lockBudget: .milliseconds(100)
        )
        let lighting = VerifiedLightingBoundary()
        let companion = KeyphoreCompanion(
            store: fixture.statusStore,
            profile: .default,
            lighting: lighting,
            keyboardHealthStore: fixture.healthStore
        )
        try companion.sync(at: .milliseconds(100))
        lighting.displaysExpected = false

        try companion.healthCheck(at: .milliseconds(1_100))

        XCTAssertEqual(
            lighting.behaviors,
            [.signal(LocalProfile.default.execution), .signal(LocalProfile.default.execution)]
        )
        XCTAssertEqual(
            fixture.healthStore.load(at: .milliseconds(1_100)),
            .connected(protocolHealthy: true)
        )
    }

    func testSleepReleasesHIDAndWakeReacquiresBeforeReplayingDurableAggregate() throws {
        let fixture = try TransportFixture()
        try fixture.statusStore.recordSignal(
            ownerID: SignalOwnerID(product: "codex", sessionID: "session", agentID: "main"),
            turnID: "turn",
            signal: .execution,
            expiresAt: .milliseconds(3_600_000),
            replacingSession: true,
            lockBudget: .milliseconds(100)
        )
        let lighting = RecoveringLightingBoundary()
        let companion = KeyphoreCompanion(
            store: fixture.statusStore,
            profile: .default,
            lighting: lighting,
            keyboardHealthStore: fixture.healthStore
        )
        let recovery = CompanionRecoveryController(companion: companion)
        try recovery.poll(at: .milliseconds(100))

        try recovery.handle(.willSleep, at: .milliseconds(200))
        try recovery.poll(at: .milliseconds(300))
        XCTAssertEqual(fixture.healthStore.load(at: .milliseconds(300)), .disconnected)

        try recovery.handle(.didWake, at: .milliseconds(400))
        try recovery.poll(at: .milliseconds(500))

        XCTAssertEqual(lighting.invalidations, 2)
        XCTAssertEqual(
            lighting.behaviors,
            [.signal(LocalProfile.default.execution), .signal(LocalProfile.default.execution)]
        )
        XCTAssertEqual(
            fixture.healthStore.load(at: .milliseconds(500)),
            .connected(protocolHealthy: true)
        )
    }

    func testSystemPowerNotificationsDriveTheRecoveryController() throws {
        let center = NotificationCenter()
        let willSleep = Notification.Name("test.will-sleep")
        let didWake = Notification.Name("test.did-wake")
        var events: [CompanionPowerEvent] = []
        let monitor = SystemPowerEventMonitor(
            notificationCenter: center,
            willSleepNotification: willSleep,
            didWakeNotification: didWake
        ) { event in
            events.append(event)
        }

        center.post(name: willSleep, object: nil)
        center.post(name: didWake, object: nil)

        withExtendedLifetime(monitor) {
            XCTAssertEqual(events, [.willSleep, .didWake])
        }
    }

    func testDisconnectChangesHealthWithoutRewritingDurableStatusOrBlockingHooks() throws {
        let fixture = try TransportFixture()
        let hook = ProductionHookHandler(store: fixture.statusStore, profile: .default)
        try hook.handle(
            Data(
                """
                {"hook_event_name":"UserPromptSubmit","session_id":"session-1","turn_id":"turn-1"}
                """.utf8
            ),
            receivedAt: .milliseconds(100)
        )
        let statusBeforeDisconnect = try fixture.statusStore.load()
        let companion = KeyphoreCompanion(
            store: fixture.statusStore,
            profile: .default,
            lighting: FailingLightingBoundary(error: SystemAir65HIDError.deviceDisappeared),
            keyboardHealthStore: fixture.healthStore
        )

        XCTAssertThrowsError(try companion.sync(at: .milliseconds(200)))
        XCTAssertEqual(try fixture.statusStore.load(), statusBeforeDisconnect)
        XCTAssertEqual(fixture.healthStore.load(at: .milliseconds(200)), .disconnected)

        let started = ContinuousClock.now
        try hook.handle(
            Data(
                """
                {"hook_event_name":"UserPromptSubmit","session_id":"session-2","turn_id":"turn-1"}
                """.utf8
            ),
            receivedAt: .milliseconds(300)
        )

        XCTAssertLessThan(started.duration(to: .now), .milliseconds(250))
        XCTAssertEqual(try fixture.statusStore.load().owners.count, 2)
    }

    func testMultipleDevicesRefuseRecoveryAndExposeActionableHealth() throws {
        let fixture = try TransportFixture()
        let lighting = FailingLightingBoundary(error: Air65DeviceSelectionError.ambiguous)
        let companion = KeyphoreCompanion(
            store: fixture.statusStore,
            profile: .default,
            lighting: lighting,
            keyboardHealthStore: fixture.healthStore
        )

        XCTAssertThrowsError(try companion.sync(at: .milliseconds(100)))

        XCTAssertEqual(fixture.healthStore.load(at: .milliseconds(100)), .ambiguous)
        XCTAssertEqual(
            AppCopy.value(.keyboardAmbiguous, language: .english),
            "Multiple Air65 V3 keyboards found. Leave only the target connected."
        )
    }

    func testCompanionRestartRecomputesAndRestoresDurableAggregate() throws {
        let fixture = try TransportFixture()
        try fixture.statusStore.recordSignal(
            ownerID: SignalOwnerID(product: "codex", sessionID: "session", agentID: "main"),
            turnID: "turn",
            signal: .attention,
            expiresAt: .milliseconds(3_600_000),
            replacingSession: false,
            lockBudget: .milliseconds(100)
        )
        let lightingBeforeRestart = VerifiedLightingBoundary()
        try KeyphoreCompanion(
            store: fixture.statusStore,
            profile: .default,
            lighting: lightingBeforeRestart
        ).sync(at: .milliseconds(100))
        let lightingAfterRestart = VerifiedLightingBoundary()

        try KeyphoreCompanion(
            store: fixture.statusStore,
            profile: .default,
            lighting: lightingAfterRestart
        ).sync(at: .milliseconds(200))

        XCTAssertEqual(
            lightingAfterRestart.behaviors,
            [.signal(LocalProfile.default.attention)]
        )
    }
}

private struct PersistedHealthProvider: KeyphoreHealthProviding {
    let store: KeyboardHealthStore
    let now: StatusTimestamp

    func currentHealth() -> KeyphoreHealth {
        .configured(keyboard: store.load(at: now))
    }
}

private struct FixedTransportProfileProvider: LocalProfileProviding {
    func currentProfile() -> LocalProfile { .default }
}

private struct FixedTransportStatusProvider: DurableStatusProviding {
    func currentOutcome() -> DurableStatusOutcome { .signalOff }
}

private final class RecordingTransportMenuLighting: LightingEmitting {
    func emit(_ behavior: LightingBehavior) {}
}

private final class EmptyTransportRuntime: KeyphoreRuntimeManaging {
    func disableOwnedHooks() {}
    func stopCompanion() {}
    func clearManagedRuntimeState() {}
}

private final class VerifiedLightingBoundary: CompanionLightingApplying, CompanionLightingVerifying {
    private(set) var behaviors: [LightingBehavior] = []
    var displaysExpected = true

    func apply(_ behavior: LightingBehavior) throws {
        behaviors.append(behavior)
        displaysExpected = true
    }

    func displays(_ behavior: LightingBehavior) throws -> Bool {
        displaysExpected
    }
}

private final class FailingLightingBoundary: CompanionLightingApplying, CompanionLightingVerifying {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func apply(_ behavior: LightingBehavior) throws { throw error }
    func displays(_ behavior: LightingBehavior) throws -> Bool { throw error }
}

private final class RecoveringLightingBoundary: CompanionLightingApplying,
    CompanionLightingRecovering
{
    private(set) var behaviors: [LightingBehavior] = []
    private(set) var invalidations = 0

    func apply(_ behavior: LightingBehavior) throws {
        behaviors.append(behavior)
    }

    func invalidateTransport() {
        invalidations += 1
    }
}

private final class TransportFixture {
    let directory: URL
    let statusStore: DurableStatusStore
    let healthStore: KeyboardHealthStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        statusStore = DurableStatusStore(url: directory.appending(path: "status.json"))
        healthStore = KeyboardHealthStore(url: directory.appending(path: "keyboard-health.json"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
