import XCTest
@testable import KeyphoreCore

final class KeyboardSelectionTests: XCTestCase {
    func testSwitchUsesActualModelProfileAndPreservesOtherModelConfiguration() throws {
        let custom = LocalProfile.default.execution.replacingAppearance(
            ZoneAppearance(effect: .backlightRipple, color: SignalColor(red: 13, green: 27, blue: 54),
                           brightness: SignalBrightness(percent: 17)!), for: .backlight)
        let v3 = LocalProfile.default.replacingAppearance(custom, for: .execution).replacingControlledZones(.both)
        let f = try SelectionFixture(profile: v3, useModelProfiles: true)
        try f.profiles.save(v3, for: .air75V3)
        let original = try Data(contentsOf: f.profiles.url(for: .air75V3))
        try f.base.signal()
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        try f.selection.save(.air75V2)
        try f.companion.sync(at: .milliseconds(100))
        XCTAssertEqual(f.lighting.writes.suffix(2).map(\.behavior), [.off(for: .both), .signal(LocalProfile.default.execution)])
        XCTAssertEqual(try f.base.ownership.load(), LightingOwnershipRecord(model: .air75V2, zones: [.backlight]))
        let editedV2 = LocalProfile.default.replacingAppearance(LocalProfile.default.completion, for: .execution)
        try f.profiles.save(editedV2, for: .air75V2)
        try f.companion.sync(at: .milliseconds(200))
        XCTAssertEqual(f.lighting.writes.last?.behavior, .signal(editedV2.execution))
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(300))
        XCTAssertEqual(f.lighting.writes.last?.behavior, .signal(v3.execution, controlledZones: .both))
        XCTAssertEqual(try Data(contentsOf: f.profiles.url(for: .air75V3)), original)
        XCTAssertEqual(try f.profiles.load(for: .air75V2), editedV2)
    }

    func testSwitchAndQuitCleanupDoNotReadTheOldTargetsProfile() throws {
        let f = try SelectionFixture(profile: .default.replacingControlledZones(.both), useModelProfiles: true)
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        try Data("corrupt old profile".utf8).write(to: f.profiles.url(for: .air75V3))
        try f.selection.save(.air75V2)
        try f.companion.sync(at: .milliseconds(100))
        XCTAssertEqual(f.lighting.writes.suffix(2).map(\.model), [.air75V3, .air75V2])
        XCTAssertEqual(f.lighting.writes[f.lighting.writes.count - 2].behavior, .off(for: .both))
        try Data("corrupt active profile".utf8).write(to: f.profiles.url(for: .air75V2))
        try f.base.quit.activate()
        try f.makeCompanion().sync(at: .milliseconds(200))
        XCTAssertEqual(f.lighting.writes.last?.model, .air75V2)
        XCTAssertEqual(f.lighting.writes.last?.behavior, .off)
        XCTAssertEqual(try f.base.ownership.load(), .empty)
        XCTAssertTrue(f.base.acknowledgement.isAcknowledged)
    }

    func testAutomaticHotSwapAndExpiredPreferenceUseTheOnlyConnectedModelsProfile() throws {
        for manualPreference in [false, true] {
            let v3 = LocalProfile.default.replacingControlledZones(.both)
            let v2 = LocalProfile.default.replacingAppearance(LocalProfile.default.completion, for: .execution)
            let f = try SelectionFixture(profile: v3, useModelProfiles: true)
            try f.profiles.save(v2, for: .air75V2)
            let v3Bytes = try Data(contentsOf: f.profiles.url(for: .air75V3))
            let v2Bytes = try Data(contentsOf: f.profiles.url(for: .air75V2))
            f.lighting.inventory = [.init(model: .air75V3, count: 1)]
            if manualPreference { try f.selection.save(.air75V3) }
            try f.base.signal()
            try f.companion.sync(at: .milliseconds(0))
            let attempts = f.lighting.attempts.count
            f.lighting.inventory = [.init(model: .air75V2, count: 1)]

            try f.companion.sync(at: .milliseconds(100))

            XCTAssertNil(try f.selection.load())
            XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.phase, .applied)
            XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.activeModel, .air75V2)
            XCTAssertNil(f.snapshots.load(at: .milliseconds(100))?.desiredModel)
            XCTAssertEqual(f.lighting.attempts.dropFirst(attempts).map(\.model), [.air75V2])
            XCTAssertEqual(f.lighting.writes.last?.behavior, .signal(v2.execution))
            XCTAssertEqual(try f.base.ownership.load(), .init(model: .air75V2, zones: [.backlight]))
            XCTAssertFalse(f.base.acknowledgement.isAcknowledged)
            XCTAssertEqual(try Data(contentsOf: f.profiles.url(for: .air75V3)), v3Bytes)
            XCTAssertEqual(try Data(contentsOf: f.profiles.url(for: .air75V2)), v2Bytes)
        }
    }

    func testExplicitSelectionIgnoresOtherModelsButNeverFallsBackOrAcceptsDuplicates() throws {
        let v2 = device(.air75V2), v3 = device(.air75V3)
        XCTAssertEqual(try Air65DeviceSelector.select(from: [v2, v3], preferredModel: .air75V2), v2)
        XCTAssertThrowsError(try Air65DeviceSelector.select(from: [v3], preferredModel: .air75V2))
        XCTAssertThrowsError(try Air65DeviceSelector.select(from: [v2, v2, v3], preferredModel: .air75V2))
        XCTAssertThrowsError(try Air65DeviceSelector.select(from: [v2, v3]))
        XCTAssertThrowsError(try Air65DeviceSelector.select(from: [v2], preferredModel: .init(rawValue: "Unknown")))
        var ordinary = v2; ordinary.usage = 6
        let adapter = NuPhyIOAdapter(discovery: InventoryDiscovery([v2, v3, ordinary]))
        XCTAssertEqual(try adapter.keyboardInventory(), [
            KeyboardInventoryEntry(model: .air75V3, count: 1), KeyboardInventoryEntry(model: .air75V2, count: 1),
        ])
    }

    func testAutomaticAmbiguityPublishesInventoryWithoutWritingEitherKeyboard() throws {
        let f = try SelectionFixture()
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(0)))
        XCTAssertTrue(f.lighting.writes.isEmpty)
        let snapshot = try XCTUnwrap(f.snapshots.load(at: .milliseconds(0)))
        XCTAssertEqual(snapshot.phase, .blocked)
        XCTAssertEqual(snapshot.failure, .ambiguous)
        XCTAssertEqual(snapshot.inventory.count, 2)
        XCTAssertNil(snapshot.activeModel)
    }

    func testSelectionIsJournaledBeforeFirstWriteAndSwitchTurnsOffOnlyOldOwnedZones() throws {
        let f = try SelectionFixture()
        try f.base.signal()
        try f.selection.save(.air75V3)
        f.lighting.beforeWrite = { model, behavior in
            let owner = try f.base.ownership.load()
            XCTAssertEqual(owner.model, model)
            XCTAssertTrue(owner.zones.contains(.backlight))
            XCTAssertEqual(behavior.strip, .unmanaged)
        }
        try f.companion.sync(at: .milliseconds(0))
        try f.selection.save(.air75V2)
        try f.companion.sync(at: .milliseconds(100))
        XCTAssertEqual(f.lighting.writes.map(\.model), [.air75V3, .air75V3, .air75V2])
        XCTAssertEqual(f.lighting.writes[1].behavior, .off)
        XCTAssertEqual(f.lighting.writes[0].behavior, f.lighting.writes[2].behavior,
                       "Identical appearances still have to be applied to a new target")
        XCTAssertEqual(try f.base.ownership.load(), LightingOwnershipRecord(model: .air75V2, zones: [.backlight]))
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.activeModel, .air75V2)
    }

    func testExplicitV3SelectionReleasesDisconnectedV2AndKeepsBothProfiles() throws {
        let v3 = LocalProfile.default.replacingControlledZones(.both)
        let v2 = LocalProfile.default.replacingAppearance(LocalProfile.default.completion, for: .execution)
        let f = try SelectionFixture(profile: v3, useModelProfiles: true)
        try f.profiles.save(v2, for: .air75V2)
        let v2Bytes = try Data(contentsOf: f.profiles.url(for: .air75V2))
        let v3Bytes = try Data(contentsOf: f.profiles.url(for: .air75V3))
        try f.base.signal()
        try f.selection.save(.air75V2)
        try f.companion.sync(at: .milliseconds(0))
        let attemptsBeforeSwitch = f.lighting.attempts.count
        f.lighting.inventory = [KeyboardInventoryEntry(model: .air75V3, count: 1)]
        try f.selection.save(.air75V3)
        try f.base.acknowledgement.acknowledge()
        let ownershipStore = f.base.ownership
        f.lighting.beforeWrite = { model, _ in
            XCTAssertEqual(model, .air75V3, "A disconnected V2 must receive no cleanup command")
            XCTAssertEqual(try ownershipStore.load(), LightingOwnershipRecord(model: .air75V3, zones: [.backlight, .strip]))
        }

        try f.companion.sync(at: .milliseconds(100))

        XCTAssertEqual(f.lighting.attempts.dropFirst(attemptsBeforeSwitch).map(\.model), [.air75V3])
        XCTAssertEqual(f.lighting.writes.last?.behavior, .signal(v3.execution, controlledZones: .both))
        XCTAssertEqual(try f.base.ownership.load(), LightingOwnershipRecord(model: .air75V3, zones: [.backlight, .strip]))
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.activeModel, .air75V3)
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.phase, .applied)
        XCTAssertEqual(f.base.health.load(at: .milliseconds(100)), .connected(protocolHealthy: true, model: .air75V3))
        XCTAssertFalse(f.base.acknowledgement.isAcknowledged, "Releasing an offline owner is not a verified off acknowledgement")
        XCTAssertEqual(try Data(contentsOf: f.profiles.url(for: .air75V2)), v2Bytes)
        XCTAssertEqual(try Data(contentsOf: f.profiles.url(for: .air75V3)), v3Bytes)

        f.lighting.inventory.append(KeyboardInventoryEntry(model: .air75V2, count: 1))
        try f.companion.sync(at: .milliseconds(200))
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(200))?.activeModel, .air75V3)
        XCTAssertEqual(f.lighting.attempts.count, attemptsBeforeSwitch + 1, "Reconnecting V2 must not steal the explicit V3 target")
    }

    func testOldTargetLostAfterDiscoveryBlocksUntilItsOffCanBeRetried() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        try f.selection.save(.air75V2)
        f.lighting.beforeValidate = { model in
            if model == .air75V3 { throw Air65DeviceSelectionError.notFound }
        }
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(100)))
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.failure, .oldTargetUnavailable)
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.activeModel, .air75V3)
        XCTAssertEqual(try f.base.ownership.load().model, .air75V3)
        XCTAssertEqual(f.lighting.writes.map(\.model), [.air75V3])
        f.lighting.beforeValidate = nil
        try f.companion.sync(at: .milliseconds(200))
        XCTAssertEqual(f.lighting.writes.map(\.model), [.air75V3, .air75V3, .air75V2])
    }

    func testEmptyInventoryAndQuitRetainDisconnectedOwnershipAndPreference() throws {
        for quitting in [false, true] {
            for manualPreference in [false, true] {
                let f = try SelectionFixture()
                f.lighting.inventory = [.init(model: .air75V3, count: 1)]
                if manualPreference { try f.selection.save(.air75V3) }
                try f.companion.sync(at: .milliseconds(0))
                let owner = try f.base.ownership.load()
                f.lighting.inventory = quitting ? [.init(model: .air75V2, count: 1)] : []
                try f.base.acknowledgement.clear()
                if quitting { try f.base.quit.activate() }
                XCTAssertThrowsError(try f.makeCompanion().sync(at: .milliseconds(100)))
                XCTAssertEqual(try f.base.ownership.load(), owner)
                XCTAssertEqual(try f.selection.load(), manualPreference ? .air75V3 : nil)
                XCTAssertFalse(f.base.acknowledgement.isAcknowledged)
                XCTAssertFalse(f.lighting.writes.contains { $0.model == .air75V2 })
            }
        }
    }

    func testMultipleKeyboardsNeedAChoiceAndKeepItOnlyWhileItsModelRemains() throws {
        let f = try SelectionFixture()
        try f.base.signal()
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(0)))
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(0))?.failure, .ambiguous)
        XCTAssertTrue(f.lighting.attempts.isEmpty)
        try f.selection.save(.air75V2)
        try f.companion.sync(at: .milliseconds(100))
        try f.companion.sync(at: .milliseconds(200))
        XCTAssertEqual(try f.selection.load(), .air75V2)
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(200))?.activeModel, .air75V2)
        XCTAssertEqual(f.lighting.attempts.count, 1)
        f.lighting.inventory = [.init(model: .air75V3, count: 1), .init(model: .air65V3, count: 1)]
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(300)))
        XCTAssertNil(try f.selection.load())
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(300))?.failure, .ambiguous)
        XCTAssertNil(f.snapshots.load(at: .milliseconds(300))?.activeModel)
        XCTAssertEqual(f.lighting.attempts.count, 1, "Neither a disconnected owner nor an ambiguous new target is written")
        XCTAssertEqual(try f.base.ownership.load(), .empty)
        XCTAssertFalse(f.base.acknowledgement.isAcknowledged)
        try f.selection.save(.air65V3)
        try f.companion.sync(at: .milliseconds(400))
        XCTAssertEqual(f.lighting.writes.last?.model, .air65V3)
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(400))?.phase, .applied)
    }

    func testDuplicateSelectedModelDoesNotDiscardPreferenceOrFallback() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V3)
        f.lighting.inventory = [.init(model: .air75V3, count: 2), .init(model: .air75V2, count: 1)]
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(0)))
        XCTAssertEqual(try f.selection.load(), .air75V3)
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(0))?.failure, .ambiguous)
        XCTAssertTrue(f.lighting.attempts.isEmpty)
    }

    func testStalePreferenceCleanupDoesNotOverwriteChoiceMadeDuringDiscovery() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        f.lighting.inventory = [.init(model: .air75V2, count: 1), .init(model: .air65V3, count: 1)]
        let otherProcessStore = KeyboardSelectionStore(url: f.selection.url)
        f.lighting.beforeInventory = {
            f.lighting.beforeInventory = nil
            try otherProcessStore.save(.air65V3)
        }
        try f.companion.sync(at: .milliseconds(100))
        XCTAssertEqual(try f.selection.load(), .air65V3)
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.desiredModel, .air65V3)
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.activeModel, .air65V3)
        XCTAssertEqual(f.lighting.attempts.map(\.model), [.air75V3, .air65V3])
    }

    func testPreferenceWritesAndConditionalClearShareTheSameLock() throws {
        let f = try SelectionFixture()
        let otherProcessStore = KeyboardSelectionStore(url: f.selection.url)
        try f.selection.save(.air75V3)
        XCTAssertFalse(try otherProcessStore.clear(ifUnchanged: .air75V2))
        XCTAssertEqual(try f.selection.load(), .air75V3)
        let lease = try CompanionProcessLease.acquire(url: f.selection.lockURL)
        try withExtendedLifetime(lease) {
            XCTAssertThrowsError(try otherProcessStore.save(.air75V2))
            XCTAssertThrowsError(try otherProcessStore.clear(ifUnchanged: .air75V3))
        }
        XCTAssertEqual(try f.selection.load(), .air75V3)
    }

    func testDiscoveryFailureDoesNotClearAnAbsentPreference() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        let owner = try f.base.ownership.load()
        f.lighting.inventory = [.init(model: .air75V2, count: 1)]
        f.lighting.beforeInventory = { throw Air65DeviceSelectionError.notFound }
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(100)))
        XCTAssertEqual(try f.selection.load(), .air75V3)
        XCTAssertEqual(try f.base.ownership.load(), owner)
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.failure, .discoveryFailed)
        XCTAssertEqual(f.lighting.attempts.map(\.model), [.air75V3])
    }

    func testAmbiguousOldTargetAndDiscoveryFailureCannotReleaseOwnership() throws {
        for discoveryFails in [false, true] {
            let f = try SelectionFixture()
            try f.selection.save(.air75V2)
            try f.companion.sync(at: .milliseconds(0))
            let owner = try f.base.ownership.load()
            try f.selection.save(.air75V3)
            f.lighting.inventory = [.init(model: .air75V3, count: 1), .init(model: .air75V2, count: 2)]
            if discoveryFails { f.lighting.beforeInventory = { throw KeyboardSelectionFailure.discoveryFailed } }
            XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(100)))
            XCTAssertEqual(try f.base.ownership.load(), owner)
            XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.failure,
                           discoveryFails ? .discoveryFailed : .oldTargetUnavailable)
            XCTAssertFalse(f.lighting.writes.contains { $0.model == .air75V3 })
        }
    }

    func testReleasingDisconnectedOwnerDoesNotMarkUnavailableNewTargetApplied() throws {
        for count in [0, 2] {
            let f = try SelectionFixture()
            try f.selection.save(.air75V2)
            try f.companion.sync(at: .milliseconds(0))
            let attempts = f.lighting.attempts.count
            f.lighting.inventory = count == 0 ? [] : [.init(model: .air75V3, count: count)]
            try f.selection.save(.air75V3)
            XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(100)))
            XCTAssertEqual(try f.base.ownership.load(), count == 0
                ? LightingOwnershipRecord(model: .air75V2, zones: [.backlight])
                : LightingOwnershipRecord(model: .air75V3, zones: []))
            XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.phase, .blocked)
            XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.failure, count == 0 ? .oldTargetUnavailable : .ambiguous)
            XCTAssertEqual(f.lighting.attempts.count, attempts + (count == 0 ? 1 : 0))
            XCTAssertFalse(f.base.acknowledgement.isAcknowledged)
        }
    }

    func testDisconnectedReleaseUsesLatestRequestWithoutWritingSupersededTarget() throws {
        for changeDuringDiscovery in [1, 2] {
            let f = try SelectionFixture()
            try f.selection.save(.air75V2)
            try f.companion.sync(at: .milliseconds(0))
            f.lighting.inventory = [.init(model: .air75V3, count: 1)]
            try f.selection.save(.air75V3)
            var discoveries = 0
            f.lighting.beforeInventory = {
                discoveries += 1
                if discoveries == 2 { XCTAssertEqual(try f.base.ownership.load(), .empty) }
                if discoveries == changeDuringDiscovery {
                    try f.selection.save(.air65V3)
                    f.lighting.inventory = [.init(model: .air65V3, count: 1)]
                }
            }
            defer { f.lighting.beforeInventory = nil }
            try f.companion.sync(at: .milliseconds(100))
            XCTAssertFalse(f.lighting.attempts.contains { $0.model == .air75V3 })
            try f.companion.sync(at: .milliseconds(200))
            XCTAssertEqual(f.lighting.attempts.map(\.model), [.air75V2, .air65V3])
            XCTAssertEqual(try f.base.ownership.load().model, .air65V3)
            XCTAssertEqual(f.snapshots.load(at: .milliseconds(200))?.activeModel, .air65V3)
            XCTAssertEqual(try f.selection.load(), .air65V3)
        }
    }

    func testDisconnectedReleaseJournalFailurePreventsNewTargetWrites() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V2)
        try f.companion.sync(at: .milliseconds(0))
        let attempts = f.lighting.attempts.count
        f.lighting.inventory = [.init(model: .air75V3, count: 1)]
        try f.selection.save(.air75V3)
        let url = f.base.ownership.url
        f.lighting.beforeInventory = {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(100)))
        XCTAssertEqual(f.lighting.attempts.count, attempts)
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.activeModel, .air75V2)
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.failure, .stateUnavailable)
    }

    func testFailedOldOffPreservesJournalAndRestartQuitsOldTargetDespiteNewPreference() throws {
        let f = try SelectionFixture(profile: .default.replacingControlledZones(.both))
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        let old = try f.base.ownership.load()
        try f.selection.save(.air75V2)
        f.lighting.beforeWrite = { _, _ in throw VIAProtocolError.readbackMismatch }
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(100)))
        XCTAssertEqual(try f.base.ownership.load(), old)
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.failure, .oldTargetOffFailed)
        f.lighting.beforeWrite = nil
        try f.base.quit.activate()
        try f.makeCompanion().sync(at: .milliseconds(200))
        XCTAssertEqual(f.lighting.writes.last?.model, .air75V3)
        XCTAssertEqual(f.lighting.writes.last?.behavior, .off(for: .both))
        XCTAssertFalse(f.lighting.writes.contains { $0.model == .air75V2 })
        XCTAssertEqual(try f.base.ownership.load(), .empty)
        XCTAssertTrue(f.base.acknowledgement.isAcknowledged)
    }

    func testJournalClearFailurePreventsAnyWriteToNewTarget() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        try f.selection.save(.air75V2)
        let url = f.base.ownership.url
        f.lighting.beforeWrite = { _, _ in
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(100)))
        XCTAssertFalse(f.lighting.writes.contains { $0.model == .air75V2 })
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.activeModel, .air75V3)
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.failure, .stateUnavailable)
    }

    func testChangedRequestDuringOldOffNeverWritesStaleB() throws {
        for changeToAutomatic in [false, true] {
            let f = try SelectionFixture()
            try f.selection.save(.air75V3)
            try f.companion.sync(at: .milliseconds(0))
            try f.selection.save(.air75V2)
            f.lighting.beforeWrite = { _, _ in
                try f.selection.save(changeToAutomatic ? nil : .air65V3)
                f.lighting.inventory = [KeyboardInventoryEntry(model: .air65V3, count: 1)]
            }
            try f.companion.sync(at: .milliseconds(100))
            XCTAssertEqual(f.lighting.writes.map(\.model), [.air75V3, .air75V3, .air65V3])
            XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.desiredModel, changeToAutomatic ? nil : .air65V3)
            XCTAssertEqual(try f.selection.load(), changeToAutomatic ? nil : .air65V3)
        }
    }

    func testHealthCheckProcessesSelectionAndDoesNotTransferStripOwnershipToV2() throws {
        let f = try SelectionFixture(profile: .default.replacingControlledZones(.both))
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        try f.selection.save(.air75V2)
        XCTAssertThrowsError(try f.companion.healthCheck(at: .milliseconds(100)))
        XCTAssertEqual(f.lighting.writes.last?.model, .air75V3)
        XCTAssertEqual(f.lighting.writes.last?.behavior, .off(for: .both))
        XCTAssertEqual(try f.base.ownership.load(), LightingOwnershipRecord(model: .air75V2, zones: []))
        XCTAssertEqual(try f.base.profiles.load().controlledZones, .both)
        try f.base.profiles.save(.default)
        try f.companion.sync(at: .milliseconds(200))
        XCTAssertEqual(f.lighting.writes.last?.model, .air75V2)
        XCTAssertEqual(try f.base.ownership.load().zones, [.backlight])
    }

    func testSelectedPreferenceSurvivesEmptyDiscoveryAndWakeWhileDuplicatesBlock() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V2)
        f.lighting.inventory = []
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(0)))
        XCTAssertTrue(f.lighting.writes.isEmpty)
        XCTAssertEqual(try f.selection.load(), .air75V2)
        f.lighting.inventory = [.init(model: .air75V3, count: 1), .init(model: .air75V2, count: 2)]
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(100)))
        XCTAssertTrue(f.lighting.writes.isEmpty)
        f.lighting.inventory[1] = KeyboardInventoryEntry(model: .air75V2, count: 1)
        let recovery = CompanionRecoveryController(companion: f.companion)
        try recovery.poll(at: .milliseconds(200))
        try recovery.handle(.willSleep, at: .milliseconds(300))
        try recovery.handle(.didWake, at: .milliseconds(400))
        try recovery.poll(at: .milliseconds(500))
        XCTAssertEqual(f.lighting.writes.map(\.model), [.air75V2, .air75V2])
    }

    func testSwitchCancelsOldPreviewButPreservesRequestCreatedDuringCleanup() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        _ = try f.base.preview.begin(preset: .execution, targetModel: .air75V3, at: .milliseconds(100))
        try f.companion.sync(at: .milliseconds(100))
        try f.selection.save(.air75V2)
        var replacement: SignalPreviewRecord?
        f.lighting.beforeWrite = { model, behavior in
            if model == .air75V3, behavior.isOff {
                replacement = try f.base.preview.begin(preset: .completion, targetModel: .air75V2, at: .milliseconds(200))
            }
        }
        try f.companion.sync(at: .milliseconds(200))
        XCTAssertEqual(try f.base.preview.load()?.id, replacement?.id)
        XCTAssertEqual(try f.base.preview.load()?.currentPreset, .completion)
        XCTAssertEqual(f.lighting.writes.last?.model, .air75V2)
        XCTAssertEqual(f.lighting.writes.last?.behavior, .signal(LocalProfile.default.completion))
    }

    func testRequestChangedDuringNewTargetValidationDoesNotPreviewOnStaleTarget() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        try f.selection.save(.air75V2)
        var requested: SignalPreviewRecord?
        f.lighting.beforeValidate = { model in
            guard model == .air75V2 else { return }
            f.lighting.beforeValidate = nil
            try f.selection.save(.air75V3)
            requested = try f.base.preview.begin(preset: .completion, targetModel: .air75V3, at: .milliseconds(100))
        }
        try f.companion.sync(at: .milliseconds(100))
        XCTAssertEqual(try f.base.preview.load()?.id, requested?.id)
        XCTAssertEqual(try f.base.preview.load()?.phase, .pending)
        XCTAssertFalse(f.lighting.writes.contains { $0.model == .air75V2 })
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.phase, .pending)
        try f.companion.sync(at: .milliseconds(200))
        XCTAssertEqual(try f.base.preview.load()?.id, requested?.id)
        XCTAssertEqual(try f.base.preview.load()?.phase, .presenting)
        XCTAssertEqual(f.lighting.writes.last?.model, .air75V3)
    }

    func testRestartDiscardsInheritedPreviewEvidenceAndReplaysOwnedTarget() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        _ = try f.base.preview.begin(targetModel: .air75V3, at: .milliseconds(100))
        try f.companion.sync(at: .milliseconds(100))
        try f.selection.save(.air75V2)
        try f.makeCompanion().sync(at: .milliseconds(200))
        XCTAssertEqual(try f.base.preview.load()?.phase, .failed)
        XCTAssertEqual(f.lighting.writes.suffix(2).map(\.model), [.air75V3, .air75V2])
    }

    func testUnknownPreferenceAndOldOrUnattributedJournalFailClosed() throws {
        let f = try SelectionFixture()
        try Data(#"{"model":"unknown"}"#.utf8).write(to: f.selection.url)
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(0)))
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(0))?.failure, .unsupportedSelection)
        XCTAssertTrue(f.lighting.writes.isEmpty)
        for json in ["[]", #"{"zones":["strip"]}"#, #"{"model":"unknown","zones":[]}"#, "corrupt"] {
            let data = Data(json.utf8)
            try data.write(to: f.base.ownership.url)
            XCTAssertThrowsError(try f.makeCompanion().sync(at: .milliseconds(100)))
            XCTAssertEqual(try Data(contentsOf: f.base.ownership.url), data)
            XCTAssertTrue(f.lighting.writes.isEmpty)
        }
    }

    func testPreviewArrivingAfterSelectionReadIsBoundToItsRequestedTarget() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V2)
        try f.companion.sync(at: .milliseconds(0))
        let writes = f.lighting.writes.count
        // This is the final-read -> preview-load interleaving: B has already been selected,
        // then the other process writes its A-bound request before the controller reads it.
        try f.selection.save(.air75V3)
        let request = try f.base.preview.begin(preset: .completion, targetModel: .air75V3, at: .milliseconds(100))
        let controller = SignalPreviewController(store: f.base.preview, lighting: f.lighting)
        XCTAssertEqual(try controller.poll(at: .milliseconds(100), profile: .default, targetModel: .air75V2,
            selectionStore: f.selection), .waitingForTarget)
        XCTAssertEqual(f.lighting.writes.count, writes)
        XCTAssertEqual(try f.base.preview.load()?.id, request.id)
        XCTAssertEqual(try f.base.preview.load()?.phase, .pending)
        try f.companion.sync(at: .milliseconds(200))
        XCTAssertEqual(try f.base.preview.load()?.id, request.id)
        XCTAssertEqual(try f.base.preview.load()?.phase, .presenting)
        XCTAssertEqual(f.lighting.writes.last?.model, .air75V3)
    }

    func testCompletedOldTargetPreviewDoesNotBlockNewTargetLiveState() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        _ = try f.base.preview.begin(preset: .completion, targetModel: .air75V3, at: .milliseconds(100))
        try f.companion.sync(at: .milliseconds(100))
        try f.companion.sync(at: .milliseconds(6_200))
        XCTAssertEqual(try f.base.preview.load()?.phase, .completed)
        try f.selection.save(.air75V2)
        try f.companion.sync(at: .milliseconds(6_300))
        XCTAssertEqual(try f.base.preview.load()?.phase, .completed)
        XCTAssertEqual(f.lighting.writes.last?.model, .air75V2)
        XCTAssertEqual(f.lighting.writes.last?.behavior, .off)
    }

    func testSelectionEnabledRuntimeRejectsUnboundPreview() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V2)
        try f.companion.sync(at: .milliseconds(0))
        _ = try f.base.preview.begin(preset: .completion, at: .milliseconds(100))
        try f.companion.sync(at: .milliseconds(100))
        XCTAssertEqual(try f.base.preview.load()?.phase, .failed)
        XCTAssertTrue(f.lighting.writes.allSatisfy { $0.behavior.isOff })
    }

    func testAbandonedTargetPreviewDoesNotStarveCurrentKeyboardLiveSignal() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V2)
        try f.companion.sync(at: .milliseconds(0))
        try f.selection.save(.air75V3)
        _ = try f.base.preview.begin(preset: .completion, targetModel: .air75V3, at: .milliseconds(100))
        try f.selection.save(.air75V2)
        try f.base.signal()
        try f.companion.sync(at: .milliseconds(200))
        XCTAssertEqual(try f.base.preview.load()?.phase, .failed)
        XCTAssertEqual(f.lighting.writes.last?.model, .air75V2)
        XCTAssertEqual(f.lighting.writes.last?.behavior, .signal(LocalProfile.default.execution))
        try f.companion.healthCheck(at: .milliseconds(1_200))
        XCTAssertEqual(f.base.health.load(at: .milliseconds(1_200)), .connected(protocolHealthy: true, model: .air75V2))
    }

    func testSnapshotThrottlesUnchangedContentButPublishesInventoryChangesAndExpires() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        try f.companion.sync(at: .milliseconds(100))
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(100))?.observedAt, .milliseconds(0))
        f.lighting.inventory.append(KeyboardInventoryEntry(model: .air65V3, count: 1))
        try f.companion.sync(at: .milliseconds(200))
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(200))?.observedAt, .milliseconds(200))
        try f.companion.sync(at: .milliseconds(1_200))
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(1_200))?.observedAt, .milliseconds(1_200))
        XCTAssertNil(f.snapshots.load(at: .milliseconds(4_201)))
    }

    func testRepeatedBlockedCleanupDoesNotAlternatePendingSnapshotsEveryPoll() throws {
        let f = try SelectionFixture()
        try f.selection.save(.air75V3)
        try f.companion.sync(at: .milliseconds(0))
        try f.selection.save(.air75V2)
        f.lighting.beforeWrite = { _, _ in throw VIAProtocolError.readbackMismatch }
        for time: UInt64 in [100, 200, 300, 1_000] {
            XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(time)))
            XCTAssertEqual(f.snapshots.load(at: .milliseconds(time))?.phase, .blocked)
            XCTAssertEqual(f.snapshots.load(at: .milliseconds(time))?.observedAt, .milliseconds(100))
        }
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(1_100)))
        XCTAssertEqual(f.snapshots.load(at: .milliseconds(1_100))?.observedAt, .milliseconds(1_100))
    }

    func testInvalidOwnershipStillExpiresTasksAndQuitDoesNotDependOnStatus() throws {
        let f = try SelectionFixture()
        try f.base.status.recordSignal(ownerID: SignalOwnerID(product: "codex", sessionID: "expired", agentID: "main"),
            turnID: "turn", signal: .completion, expiresAt: .milliseconds(100),
            replacingSession: true, lockBudget: .milliseconds(100))
        try Data("[]".utf8).write(to: f.base.ownership.url)
        XCTAssertThrowsError(try f.companion.sync(at: .milliseconds(200)))
        XCTAssertTrue(try f.base.status.load().owners.isEmpty)
        try f.base.ownership.save(LightingOwnershipRecord(model: .air75V3, zones: [.backlight]))
        try Data("invalid status".utf8).write(to: f.base.status.url)
        try f.base.quit.activate()
        try f.makeCompanion().sync(at: .milliseconds(300))
        XCTAssertEqual(f.lighting.writes.last?.model, .air75V3)
        XCTAssertTrue(f.base.acknowledgement.isAcknowledged)
    }

    private func device(_ model: SupportedKeyboardModel) -> HIDDeviceDescriptor {
        HIDDeviceDescriptor(id: model.rawValue, vendorID: 0x19f5,
            productID: model == .air75V2 ? 0x3246 : 0x1028,
            product: model == .air75V2 ? "NuPhy Air75 V2" : "Air75 V3", bus: .usb,
            interfaceNumber: model == .air75V2 ? 1 : 3,
            usagePage: model == .air75V2 ? 0xff60 : 1, usage: model == .air75V2 ? 0x61 : 0)
    }
}

private final class SelectionFixture {
    let base: NativeLightingFixture
    let selection: KeyboardSelectionStore
    let snapshots: KeyboardSelectionSnapshotStore
    let lighting = SelectionLighting()
    let profiles: KeyboardProfileStore
    let useModelProfiles: Bool
    lazy var companion = makeCompanion()
    init(profile: LocalProfile = .default, useModelProfiles: Bool = false) throws {
        base = try NativeLightingFixture(profile: profile)
        self.useModelProfiles = useModelProfiles
        profiles = KeyboardProfileStore(directory: base.directory.appending(path: "profiles"))
        if useModelProfiles { try profiles.save(profile, for: .air75V3) }
        selection = KeyboardSelectionStore(url: base.directory.appending(path: "selection.json"))
        snapshots = KeyboardSelectionSnapshotStore(url: base.directory.appending(path: "selection-snapshot.json"))
    }
    func makeCompanion() -> KeyphoreCompanion {
        KeyphoreCompanion(store: base.status, profileProvider: { [base, profiles, useModelProfiles] model in
            if useModelProfiles {
                guard let model else { throw KeyboardSelectionFailure.stateUnavailable }
                return try profiles.load(for: model)
            }
            return try base.profiles.load()
        },
            lighting: lighting, keyboardHealthStore: base.health, previewStore: base.preview,
            signalOffAcknowledgement: base.acknowledgement, quitGate: base.quit, ownershipStore: base.ownership,
            selectionStore: selection, selectionSnapshotStore: snapshots)
    }
}

private final class SelectionLighting: CompanionLightingEvidenceApplying, CompanionLightingVerifying,
    CompanionLightingRecovering, CompanionLightingValidating, CompanionKeyboardSelecting {
    struct Write { let model: SupportedKeyboardModel; let behavior: LightingBehavior }
    var inventory = [KeyboardInventoryEntry(model: .air75V3, count: 1), KeyboardInventoryEntry(model: .air75V2, count: 1)]
    var connectedModel: SupportedKeyboardModel?
    var selected: SupportedKeyboardModel?
    var writes: [Write] = []
    var attempts: [Write] = []
    var beforeWrite: ((SupportedKeyboardModel, LightingBehavior) throws -> Void)?
    var beforeValidate: ((SupportedKeyboardModel) throws -> Void)?
    var beforeInventory: (() throws -> Void)?
    func keyboardInventory() throws -> [KeyboardInventoryEntry] {
        try beforeInventory?()
        return inventory
    }
    func selectTarget(_ model: SupportedKeyboardModel?) throws {
        try KeyboardSelectionStore.validate(model)
        selected = model
        connectedModel = nil
    }
    func validate(_ behavior: LightingBehavior) throws {
        let count = inventory.first { $0.model == selected }?.count ?? 0
        guard count == 1, let selected else {
            throw count > 1 ? Air65DeviceSelectionError.ambiguous : .notFound
        }
        connectedModel = selected
        try beforeValidate?(selected)
        if selected == .air75V2 { try VIALightingAdapter.validate(behavior) }
    }
    func apply(_ behavior: LightingBehavior) throws { _ = try applyAndVerify(behavior) }
    func applyAndVerify(_ behavior: LightingBehavior) throws -> NuPhyIOEvidence {
        if let selected { attempts.append(Write(model: selected, behavior: behavior)) }
        try validate(behavior)
        let model = connectedModel!
        try beforeWrite?(model, behavior)
        writes.append(Write(model: model, behavior: behavior))
        return NuPhyIOEvidence(protocolReadbackSucceeded: true, visualConfirmation: .notRequested,
            mainState: [], rhythmBefore: [0], rhythmAfter: [0], unmanagedZonesPreserved: true,
            unmanagedZoneProtection: model == .air75V2 ? .untouchedProtocolChannel : .readback)
    }
    func displays(_ behavior: LightingBehavior) throws -> Bool {
        try validate(behavior)
        return writes.last?.model == selected && writes.last?.behavior == behavior
    }
    func invalidateTransport() { connectedModel = nil }
}

private final class InventoryDiscovery: Air65TransportDiscovering {
    let devices: [HIDDeviceDescriptor]
    init(_ devices: [HIDDeviceDescriptor]) { self.devices = devices }
    func discover() throws -> [HIDDeviceDescriptor] { devices }
    func open(_ descriptor: HIDDeviceDescriptor) throws -> any Air65ReportTransport {
        XCTFail("Inventory must not open an individual transport")
        throw Air65DeviceSelectionError.unsupported
    }
    func resetDiscoveryState() {}
}
