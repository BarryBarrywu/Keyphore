import Foundation
import KeyphoreCore
import XCTest

final class SignalPatternAcceptanceTests: XCTestCase {
    func testCustomIdleFollowsTaskPriorityAndCompletionExpiryWithoutCreatingOwners() throws {
        let idle = testSignalAppearance(color: SignalColor(red: 12, green: 34, blue: 56))
        let profile = LocalProfile.default.replacingAppearance(idle, forPreset: .idle).replacingControlledZones(.both)
        let fixture = try NativeLightingFixture(profile: profile)
        let companion = fixture.companion()
        try companion.sync(at: .milliseconds(0))
        XCTAssertEqual(fixture.lighting.behaviors.last, .signal(idle, controlledZones: .both))
        XCTAssertTrue(try fixture.status.load().owners.isEmpty)
        XCTAssertFalse(fixture.acknowledgement.isAcknowledged)
        for (index, signal) in [CodexSignal.completion, .execution, .attention].enumerated() {
            try fixture.status.recordSignal(ownerID: SignalOwnerID(product: "codex", sessionID: String(index), agentID: "main"),
                                            turnID: "turn", signal: signal, expiresAt: .milliseconds(UInt64(3 - index) * 1_000),
                                            replacingSession: true, lockBudget: .milliseconds(100))
        }
        try companion.sync(at: .milliseconds(100))
        XCTAssertEqual(fixture.lighting.behaviors.last, .signal(profile.attention, controlledZones: .both))
        try companion.sync(at: .milliseconds(1_000))
        XCTAssertEqual(fixture.lighting.behaviors.last, .signal(profile.execution, controlledZones: .both))
        try companion.sync(at: .milliseconds(2_000))
        XCTAssertEqual(fixture.lighting.behaviors.last, .signal(profile.completion, controlledZones: .both))
        try companion.sync(at: .milliseconds(3_000))
        XCTAssertEqual(fixture.lighting.behaviors.last, .signal(idle, controlledZones: .both))
        XCTAssertTrue(try fixture.status.load().owners.isEmpty)
        XCTAssertEqual(try fixture.status.outcome(at: .milliseconds(3_000)), .signalOff)
    }

    func testIdleHonorsManagedZonesAndQuitAlwaysTurnsThemOff() throws {
        let idle = testSignalAppearance(color: SignalColor(red: 12, green: 34, blue: 56))
        for zones in ControlledZones.allCases {
            let profile = LocalProfile.default.replacingAppearance(idle, forPreset: .idle).replacingControlledZones(zones)
            let fixture = try NativeLightingFixture(profile: profile)
            let companion = fixture.companion()
            try companion.sync(at: .milliseconds(0))
            XCTAssertEqual(fixture.lighting.behaviors.last, .signal(idle, controlledZones: zones))
            try companion.healthCheck(at: .milliseconds(100))
            XCTAssertEqual(fixture.lighting.behaviors.count, 1)
            try fixture.quit.activate()
            try companion.sync(at: .milliseconds(200))
            XCTAssertEqual(fixture.lighting.behaviors.last, .off(for: zones))
            XCTAssertTrue(fixture.acknowledgement.isAcknowledged)
            XCTAssertEqual(try fixture.ownership.load().zones, [])
        }
    }

    func testSleepPausesIdleAndWakeAndDisconnectRecoverLatestProfile() throws {
        let idle = testSignalAppearance(color: SignalColor(red: 12, green: 34, blue: 56))
        let profile = LocalProfile.default.replacingAppearance(idle, forPreset: .idle).replacingControlledZones(.strip)
        let fixture = try NativeLightingFixture(profile: profile)
        let companion = fixture.companion()
        let recovery = CompanionRecoveryController(companion: companion)
        try recovery.poll(at: .milliseconds(0))
        try recovery.handle(.willSleep, at: .milliseconds(100))
        try fixture.profiles.save(LocalProfile.default.replacingControlledZones(.strip))
        try recovery.poll(at: .milliseconds(200))
        try recovery.healthCheck(at: .milliseconds(200))
        XCTAssertEqual(fixture.lighting.behaviors, [.signal(idle, controlledZones: .strip)])
        try recovery.handle(.didWake, at: .milliseconds(300))
        try recovery.poll(at: .milliseconds(400))
        XCTAssertEqual(fixture.lighting.behaviors.last, .off(for: .strip))
        try companion.transportInterrupted(at: .milliseconds(500))
        try fixture.profiles.save(profile)
        try recovery.poll(at: .milliseconds(600))
        XCTAssertEqual(fixture.lighting.behaviors.last, .signal(idle, controlledZones: .strip))
        XCTAssertEqual(fixture.lighting.invalidations, 3)
    }

    func testQuitReverifiesOffEvenWhenIdleOffWasCachedBeforeExternalHardwareDrift() throws {
        let fixture = try NativeLightingFixture()
        let companion = fixture.companion()
        try companion.sync(at: .milliseconds(0))
        fixture.lighting.actual = .signal(LocalProfile.default.execution)
        try fixture.acknowledgement.clear()
        try fixture.quit.activate()
        fixture.lighting.willApply = { _ in
            XCTAssertFalse(fixture.acknowledgement.isAcknowledged)
            XCTAssertEqual(try fixture.ownership.load().zones, [.backlight])
        }
        try companion.sync(at: .milliseconds(100))
        XCTAssertEqual(fixture.lighting.behaviors, [.off, .off])
        XCTAssertEqual(fixture.lighting.actual, .off)
        XCTAssertEqual(try fixture.ownership.load().zones, [])
        XCTAssertTrue(fixture.acknowledgement.isAcknowledged)
        fixture.lighting.willApply = { _ in }
    }

    func testQuitDoesNotAcknowledgeUntilVerifiedOffAndOwnershipCleanupBothSucceed() throws {
        let fixture = try NativeLightingFixture(profile: LocalProfile.default.replacingControlledZones(.both))
        try fixture.signal()
        let companion = fixture.companion()
        try companion.sync(at: .milliseconds(0))
        try fixture.quit.activate()
        fixture.lighting.didApply = {
            try! FileManager.default.removeItem(at: fixture.ownership.url)
            try! FileManager.default.createDirectory(at: fixture.ownership.url, withIntermediateDirectories: false)
        }
        XCTAssertThrowsError(try companion.sync(at: .milliseconds(100)))
        XCTAssertFalse(fixture.acknowledgement.isAcknowledged)
        XCTAssertEqual(fixture.lighting.behaviors.last, .off(for: .both))
        fixture.lighting.didApply = {}
        try FileManager.default.removeItem(at: fixture.ownership.url)
        try fixture.ownership.save(LightingOwnershipRecord(model: .air75V3, zones: [.backlight, .strip]))
        try companion.sync(at: .milliseconds(200))
        XCTAssertTrue(fixture.acknowledgement.isAcknowledged)
        XCTAssertEqual(try fixture.ownership.load().zones, [])
        let cleared = try Data(contentsOf: fixture.ownership.url)
        try companion.sync(at: .milliseconds(300))
        XCTAssertEqual(try Data(contentsOf: fixture.ownership.url), cleared)
    }

    func testNativeEffectIsAppliedOnceAcrossPollingAndHealthChecks() throws {
        let fixture = try NativeLightingFixture()
        try fixture.signal()
        let companion = fixture.companion()
        for time in stride(from: UInt64(0), through: 4_000, by: 100) {
            try companion.sync(at: .milliseconds(time))
            if time % 1_000 == 0 { try companion.healthCheck(at: .milliseconds(time)) }
        }
        XCTAssertEqual(fixture.lighting.behaviors, [.signal(LocalProfile.default.execution)])
        XCTAssertEqual(fixture.lighting.checked.count, 5)
        XCTAssertEqual(fixture.health.load(at: .milliseconds(4_000)), .connected(protocolHealthy: true, model: .air75V3))
    }

    func testOwnershipTransitionReleasesOnlyPreviouslyManagedZones() throws {
        let fixture = try NativeLightingFixture()
        try fixture.signal()
        let companion = fixture.companion()
        try companion.sync(at: .milliseconds(0))
        try fixture.profiles.save(LocalProfile.default.replacingControlledZones(.both))
        try companion.sync(at: .milliseconds(100))
        try fixture.profiles.save(LocalProfile.default.replacingControlledZones(.strip))
        try companion.sync(at: .milliseconds(200))
        XCTAssertEqual(fixture.lighting.behaviors, [
            .signal(LocalProfile.default.execution),
            .signal(LocalProfile.default.execution, controlledZones: .both),
            .off(for: .backlight),
            .signal(LocalProfile.default.execution, controlledZones: .strip),
        ])
        XCTAssertEqual(try fixture.ownership.load().zones, [.strip])
        try fixture.quit.activate()
        try companion.sync(at: .milliseconds(300))
        XCTAssertEqual(fixture.lighting.behaviors.last, .off(for: .strip))
        XCTAssertTrue(fixture.acknowledgement.isAcknowledged)
    }

    func testFailedOwnershipChangePersistsUnionForRestartAndQuit() throws {
        let fixture = try NativeLightingFixture()
        try fixture.signal()
        let companion = fixture.companion()
        try companion.sync(at: .milliseconds(0))
        try fixture.profiles.save(LocalProfile.default.replacingControlledZones(.strip))
        fixture.lighting.willApply = { behavior in
            XCTAssertEqual(try fixture.ownership.load().zones, [.backlight, .strip])
            if case .signal = behavior.strip { throw SystemAir65HIDError.deviceDisappeared }
        }
        XCTAssertThrowsError(try companion.sync(at: .milliseconds(100)))
        XCTAssertEqual(try fixture.ownership.load().zones, [.backlight, .strip])
        fixture.lighting.willApply = { _ in }
        try fixture.quit.activate()
        try Data("corrupt".utf8).write(to: fixture.status.url)
        let restarted = fixture.companion(profileProvider: { throw NuPhyIOAdapterError.invalidLightState })
        try restarted.sync(at: .milliseconds(200))
        XCTAssertEqual(fixture.lighting.behaviors.last, .off(for: .both))
        XCTAssertTrue(fixture.acknowledgement.isAcknowledged)
    }

    func testPreviewUsesTheSameProfileSnapshotAsOwnershipJournal() throws {
        let fixture = try NativeLightingFixture()
        _ = try fixture.preview.begin(at: .milliseconds(0))
        var reads = 0
        let companion = fixture.companion {
            reads += 1
            return LocalProfile.default.replacingControlledZones(reads == 1 ? .backlight : .both)
        }
        try companion.sync(at: .milliseconds(0))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(fixture.lighting.behaviors.last?.strip, .unmanaged)
        XCTAssertEqual(try fixture.ownership.load().zones, [.backlight])
    }

    func testFailedApplyReconnectAndOffAcknowledgement() throws {
        let fixture = try NativeLightingFixture(profile: LocalProfile.default.replacingControlledZones(.both))
        try fixture.signal()
        let companion = fixture.companion()
        fixture.lighting.error = SystemAir65HIDError.deviceDisappeared
        XCTAssertThrowsError(try companion.sync(at: .milliseconds(0)))
        XCTAssertFalse(fixture.acknowledgement.isAcknowledged)
        fixture.lighting.error = nil
        try companion.transportInterrupted(at: .milliseconds(100))
        try companion.sync(at: .milliseconds(200))
        XCTAssertEqual(fixture.lighting.invalidations, 1)
        XCTAssertEqual(fixture.lighting.behaviors.last, .signal(LocalProfile.default.execution, controlledZones: .both))
        try fixture.status.reset(lockBudget: .milliseconds(100))
        try companion.healthCheck(at: .milliseconds(300))
        XCTAssertEqual(fixture.lighting.behaviors.last, .off(for: .both))
        XCTAssertTrue(fixture.acknowledgement.isAcknowledged)
    }
}
