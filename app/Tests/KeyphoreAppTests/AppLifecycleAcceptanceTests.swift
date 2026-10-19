import AppKit
import SwiftUI
import XCTest
import KeyphoreCore

@MainActor
final class AppLifecycleAcceptanceTests: XCTestCase {
    func testBackgroundAutomaticSelectionRefreshReplacesCachedManualPreference() throws {
        let f = try KeyboardMenuFixture(desired: .air75V2, active: .air75V2)
        XCTAssertEqual(f.state.desiredKeyboardModel, .air75V2)
        try f.selection.save(nil)
        try f.snapshots.save(KeyboardSelectionSnapshot(desiredModel: nil, activeModel: .air75V3,
            inventory: [KeyboardInventoryEntry(model: .air75V3, count: 1)], phase: .applied))
        f.state.refreshKeyboardSelection()
        XCTAssertNil(f.state.desiredKeyboardModel)
        XCTAssertEqual(f.state.activeKeyboardModel, .air75V3)
        XCTAssertTrue(f.state.keyboardSelectionIsApplied)
        XCTAssertFalse(f.state.keyboardSelectionAllowsPreview, "The old V2 health cannot authorize a V3 preview")
        f.health.keyboard = .connected(protocolHealthy: true, model: .air75V3)
        f.state.refresh()
        f.state.beginSignalPreview(for: .attention)
        XCTAssertEqual(try f.preview.load()?.targetModel, .air75V3)
    }

    func testStatusKeyboardSubmenuInvokesRealActionsBeforeAgentSetupIsReady() throws {
        let f = try KeyboardMenuFixture(configured: false)
        XCTAssertEqual(f.state.menuState, .configurationRequired)
        let delegate = KeyphoreAppDelegate(state: f.state)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let submenu = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "keyboard-selection" }?.submenu)
        let v2 = try keyboardMenuItem(submenu, model: .air75V2)
        XCTAssertTrue(v2.isEnabled)
        XCTAssertTrue(v2.target === delegate)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(v2.action), to: v2.target, from: v2))
        XCTAssertEqual(try f.selection.load(), .air75V2)
        XCTAssertEqual(f.state.activeKeyboardModel, .air75V3)
        XCTAssertEqual(f.state.keyboardSelectionMessageKey, .keyboardSelectionPending)
        XCTAssertFalse(f.state.keyboardSelectionAllowsPreview)
        delegate.menuNeedsUpdate(submenu)
        XCTAssertEqual(try keyboardMenuItem(submenu, model: .air75V2).state, .on)
        let automatic = try keyboardMenuItem(submenu, model: nil)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(automatic.action), to: automatic.target, from: automatic))
        XCTAssertNil(try f.selection.load())
    }

    func testNativeMenuRechecksStaleItemsAndRefreshesInventoryWhenExpanded() throws {
        let f = try KeyboardMenuFixture()
        let delegate = KeyphoreAppDelegate(state: f.state)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let submenu = try XCTUnwrap(menu.items.first { $0.submenu != nil }?.submenu)
        let oldV2 = try keyboardMenuItem(submenu, model: .air75V2)
        try f.snapshots.save(KeyboardSelectionSnapshot(desiredModel: nil, activeModel: .air75V3,
            inventory: [KeyboardInventoryEntry(model: .air75V3, count: 1)], phase: .applied))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(oldV2.action), to: oldV2.target, from: oldV2))
        XCTAssertNil(try f.selection.load(), "A disappeared menu item must not create a manual preference")
        XCTAssertTrue(f.state.keyboardSelectionFailed)
        delegate.menuNeedsUpdate(submenu)
        XCTAssertFalse(submenu.items.contains { $0.representedObject as? String == SupportedKeyboardModel.air75V2.rawValue })
        let oldV3 = try keyboardMenuItem(submenu, model: .air75V3)
        try f.snapshots.save(KeyboardSelectionSnapshot(desiredModel: nil, activeModel: .air75V3,
            inventory: [KeyboardInventoryEntry(model: .air75V3, count: 1)], phase: .applied,
            observedAt: .milliseconds(StatusTimestamp.now.millisecondsSince1970 - 10_000)))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(oldV3.action), to: oldV3.target, from: oldV3))
        XCTAssertNil(try f.selection.load())
        XCTAssertNil(f.state.keyboardSelectionSnapshot)
        delegate.menuNeedsUpdate(submenu)
        XCTAssertFalse(try keyboardMenuItem(submenu, model: nil).isEnabled)
    }

    func testDuplicateAndDisconnectedKeyboardMenuOptionsRemainVisibleButDisabled() throws {
        let f = try KeyboardMenuFixture(desired: .air75V2, active: nil,
            inventory: [KeyboardInventoryEntry(model: .air75V3, count: 2)])
        let delegate = KeyphoreAppDelegate(state: f.state)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let submenu = try XCTUnwrap(menu.items.first { $0.submenu != nil }?.submenu)
        XCTAssertFalse(try keyboardMenuItem(submenu, model: .air75V3).isEnabled)
        XCTAssertFalse(try keyboardMenuItem(submenu, model: .air75V2).isEnabled)
        XCTAssertTrue(try keyboardMenuItem(submenu, model: .air75V2).title.contains(AppCopy.value(.keyboardSelectionDisconnected)))
        XCTAssertTrue(try keyboardMenuItem(submenu, model: nil).isEnabled)
        XCTAssertFalse(f.state.requestKeyboardSelection(.air75V3))
        XCTAssertEqual(try f.selection.load(), .air75V2)
        try f.snapshots.save(KeyboardSelectionSnapshot(desiredModel: .air75V2, activeModel: nil,
            inventory: [], phase: .blocked, failure: .notFound))
        delegate.menuNeedsUpdate(submenu)
        XCTAssertFalse(submenu.items.filter { $0.action != nil }.contains { $0.isEnabled })
        XCTAssertEqual(f.state.keyboardSelectionMessageKey, .keyboardSelectionNoConnected)
    }

    func testKeyboardSelectionActionsStayDisabledDuringStartup() async throws {
        let f = try KeyboardMenuFixture(starting: true)
        XCTAssertTrue(f.state.isStarting)
        XCTAssertFalse(f.state.canRequestKeyboardSelection(nil))
        XCTAssertFalse(f.state.requestKeyboardSelection(.air75V2))
        XCTAssertNil(try f.selection.load())
        await f.state.waitForStartup()
    }

    private func keyboardMenuItem(_ menu: NSMenu, model: SupportedKeyboardModel?) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.representedObject as? String == (model?.rawValue ?? "") })
    }

    func testAppInstanceLockRejectsOverlapAndReleasesOnExit() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "app-instance.lock")
        var first: KeyphoreAppInstanceLock? = try KeyphoreAppInstanceLock(url: url)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try KeyphoreAppInstanceLock(url: url)) {
            XCTAssertEqual($0 as? KeyphoreAppInstanceLock.Failure, .alreadyRunning)
        }
        first = nil
        XCTAssertNoThrow(try KeyphoreAppInstanceLock(url: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Unlock must not remove the shared lock inode")
    }

    func testAppInstanceLockRejectsSymlinkWithoutTouchingTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "unrelated")
        try Data("preserve".utf8).write(to: target)
        let url = directory.appending(path: "app-instance.lock")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try KeyphoreAppInstanceLock(url: url))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "preserve")
    }

    func testSelectingSignalPreviewRequestsOnlyThatSignalAndCanRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignalPreviewStore(url: directory.appending(path: "preview.json"))
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(keyboard: .connected(protocolHealthy: true)), profiles: AppProfile(),
                durableStatus: AppDurableStatus(), lighting: AppLighting(), runtime: AppRecordingRuntime()
            ),
            previewStore: store
        )
        var requestIDs = Set<String>()
        for preset: LightingPreset in [.attention, .completion, .idle, .execution, .execution] {
            state.beginSignalPreview(for: preset)
            let record = try XCTUnwrap(store.load())
            XCTAssertEqual(record.requestedPreset, preset)
            XCTAssertEqual(record.phase, .pending)
            XCTAssertEqual(state.previewRecord, record)
            XCTAssertTrue(requestIDs.insert(record.id).inserted)
            XCTAssertEqual(state.snapshot.currentSignal, .signalOff)
            XCTAssertEqual(state.snapshot.profile, .default)
        }
        state.beginSignalPreview()
        XCTAssertNil(try store.load()?.requestedPreset, "Device check still requests the full diagnostic sequence")
    }

    func testKeyboardTargetPickerWritesRequestAndWaitsForCompanionApplication() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = KeyboardSelectionStore(url: directory.appending(path: "selection.json"))
        let selectionSnapshot = KeyboardSelectionSnapshotStore(url: directory.appending(path: "selection-snapshot.json"))
        let preview = SignalPreviewStore(url: directory.appending(path: "preview.json"))
        try selectionSnapshot.save(KeyboardSelectionSnapshot(
            desiredModel: nil,
            activeModel: .air75V3,
            inventory: [
                KeyboardInventoryEntry(model: .air75V3, count: 1),
                KeyboardInventoryEntry(model: .air75V2, count: 1),
            ],
            phase: .applied
        ))
        let health = AppMutableHealth(.connected(protocolHealthy: true, model: .air75V3))
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: health,
                profiles: AppProfile(), durableStatus: AppDurableStatus(),
                lighting: AppLighting(), runtime: AppRecordingRuntime()
            ),
            previewStore: preview,
            keyboardSelectionStore: selection,
            keyboardSelectionSnapshotStore: selectionSnapshot
        )

        XCTAssertEqual(
            keyboardTargetOptions(desired: state.desiredKeyboardModel, snapshot: state.keyboardSelectionSnapshot),
            [
                KeyboardTargetOption(model: nil, connectedCount: 2),
                KeyboardTargetOption(model: .air75V3, connectedCount: 1),
                KeyboardTargetOption(model: .air75V2, connectedCount: 1),
            ]
        )
        XCTAssertTrue(state.keyboardSelectionAllowsPreview)

        state.requestKeyboardSelection(.air75V2)

        XCTAssertEqual(try selection.load(), .air75V2)
        XCTAssertEqual(state.desiredKeyboardModel, .air75V2)
        XCTAssertEqual(state.activeKeyboardModel, .air75V3)
        XCTAssertEqual(keyboardSelectionStatusKey(
            desired: state.desiredKeyboardModel,
            snapshot: state.keyboardSelectionSnapshot,
            failed: state.keyboardSelectionFailed
        ), .keyboardSelectionPending)
        XCTAssertFalse(state.keyboardSelectionAllowsPreview)
        state.beginSignalPreview(for: .attention)
        XCTAssertNil(try preview.load())

        try selectionSnapshot.save(KeyboardSelectionSnapshot(
            desiredModel: .air75V2,
            activeModel: .air75V2,
            inventory: [
                KeyboardInventoryEntry(model: .air75V3, count: 1),
                KeyboardInventoryEntry(model: .air75V2, count: 1),
            ],
            phase: .applied
        ))
        state.refreshKeyboardSelection()

        XCTAssertEqual(state.activeKeyboardModel, .air75V2)
        XCTAssertFalse(state.keyboardSelectionAllowsPreview, "Old V3 health must not make the routed V2 ready")
        health.keyboard = .connected(protocolHealthy: true, model: .air75V2)
        state.refresh()
        XCTAssertTrue(state.keyboardSelectionAllowsPreview)
        state.beginSignalPreview(for: .attention)
        XCTAssertEqual(try preview.load()?.requestedPreset, .attention)
        XCTAssertEqual(try preview.load()?.targetModel, .air75V2)

        state.requestKeyboardSelection(SupportedKeyboardModel(rawValue: "Unknown keyboard"))
        XCTAssertTrue(state.keyboardSelectionFailed)
        XCTAssertEqual(state.desiredKeyboardModel, .air75V2)
        XCTAssertEqual(try selection.load(), .air75V2, "Invalid Picker values must not become automatic")
    }

    func testPhysicalPreviewWorksWithoutAgentSetupAndRejectsUnavailableTargets() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = KeyboardSelectionStore(url: directory.appending(path: "selection.json"))
        let snapshots = KeyboardSelectionSnapshotStore(url: directory.appending(path: "selection-snapshot.json"))
        let preview = SignalPreviewStore(url: directory.appending(path: "preview.json"))
        try selection.save(.air75V2)
        func publish(_ phase: KeyboardSelectionPhase, at time: StatusTimestamp = .now) throws {
            try snapshots.save(KeyboardSelectionSnapshot(desiredModel: .air75V2, activeModel: .air75V2,
                inventory: [KeyboardInventoryEntry(model: .air75V2, count: 1)], phase: phase, observedAt: time))
        }
        try publish(.applied)
        let health = AppMutableHealth(.connected(protocolHealthy: true, model: .air75V2))
        health.isConfigured = false
        let runtime = AppRecordingRuntime()
        let state = KeyphoreAppState(lifecycle: KeyphoreLifecycle(
            health: health, profiles: AppProfile(), durableStatus: AppDurableStatus(),
            lighting: AppLighting(), runtime: runtime), previewStore: preview,
            keyboardSelectionStore: selection, keyboardSelectionSnapshotStore: snapshots)
        XCTAssertEqual(state.menuState, .configurationRequired)
        XCTAssertTrue(state.canPreviewLighting)
        state.beginSignalPreview(for: .attention)
        let record = try XCTUnwrap(preview.load(), "Physical testing must not require Agent hook configuration")
        XCTAssertEqual(record.requestedPreset, .attention)
        XCTAssertEqual(record.targetModel, .air75V2)
        XCTAssertTrue(runtime.actions.isEmpty, "Physical preview must not approve hooks or start a Companion")
        try FileManager.default.removeItem(at: preview.url)

        try publish(.pending)
        state.beginSignalPreview()
        XCTAssertNil(try preview.load())
        try publish(.applied)
        health.keyboard = .disconnected
        state.beginSignalPreview()
        XCTAssertNil(try preview.load())
        health.keyboard = .connected(protocolHealthy: true, model: .air75V3)
        state.beginSignalPreview()
        XCTAssertNil(try preview.load(), "Health from another model cannot authorize the selected V2")
        health.keyboard = .connected(protocolHealthy: true, model: .air75V2)
        try publish(.applied, at: .milliseconds(0))
        state.beginSignalPreview()
        XCTAssertNil(try preview.load(), "An expired Companion heartbeat cannot authorize physical preview")
        XCTAssertTrue(runtime.actions.isEmpty)
    }

    func testPhysicalPreviewWaitsForSetupAndRemovalOperations() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for removing in [false, true] {
            let preview = SignalPreviewStore(url: directory.appending(path: "preview-\(removing).json"))
            let setup = GuidedSetup(hosts: AppHostDetector(), integration: AppSetupIntegration(),
                                    keyboard: AppKeyboardHealth())
            let state = KeyphoreAppState(lifecycle: KeyphoreLifecycle(
                health: AppHealth(keyboard: .connected(protocolHealthy: true, model: .air75V2)),
                profiles: AppProfile(), durableStatus: AppDurableStatus(),
                lighting: AppLighting(), runtime: AppRecordingRuntime()), guidedSetup: setup,
                previewStore: preview,
                managedRemoval: ManagedRemoval(integration: AppManagedRemovalIntegration()))
            XCTAssertTrue(state.canPreviewLighting)
            if removing { state.confirmManagedRemoval() } else { state.configureAfterReview() }
            XCTAssertTrue(removing ? state.removalIsWorking : state.setupIsWorking)
            XCTAssertFalse(state.canPreviewLighting)
            state.beginSignalPreview(for: .attention)
            XCTAssertNil(try preview.load())
            while state.setupIsWorking || state.removalIsWorking { await Task.yield() }
        }
    }

    func testSignalSettingsReadAndWriteOnlyTheAppliedTargetProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = KeyboardProfileStore(directory: directory.appending(path: "profiles"))
        let selection = KeyboardSelectionStore(url: directory.appending(path: "selection.json"))
        let selectionSnapshot = KeyboardSelectionSnapshotStore(url: directory.appending(path: "selection-snapshot.json"))
        let v3 = LocalProfile.default.replacingAppearance(SignalAppearance(
            isVisible: true,
            backlight: ZoneAppearance(
                effect: .backlightRipple,
                color: SignalColor(red: 90, green: 80, blue: 70),
                direction: .reverse
            ),
            strip: LocalProfile.default.execution.strip
        ), forPreset: .execution)
        try profiles.save(v3, for: .air75V3)
        try profiles.save(.default, for: .air75V2)
        try selectionSnapshot.save(KeyboardSelectionSnapshot(
            desiredModel: nil,
            activeModel: .air75V3,
            inventory: [
                KeyboardInventoryEntry(model: .air75V3, count: 1),
                KeyboardInventoryEntry(model: .air75V2, count: 1),
            ],
            phase: .applied
        ))
        let health = AppMutableHealth(.connected(protocolHealthy: true, model: .air75V3))
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: health,
                profiles: AppKeyboardProfiles(store: profiles, selection: selectionSnapshot),
                durableStatus: AppDurableStatus(), lighting: AppLighting(), runtime: AppRecordingRuntime()
            ),
            keyboardProfileStore: profiles,
            keyboardSelectionStore: selection,
            keyboardSelectionSnapshotStore: selectionSnapshot
        )

        XCTAssertEqual(state.profileModel, .air75V3)
        XCTAssertEqual(state.snapshot.profile, v3)
        XCTAssertTrue(state.keyboardProfileAllowsEditing)

        state.requestKeyboardSelection(.air75V2)
        state.updateAppearance(LocalProfile.default.attention, for: LightingPreset.execution, expectedModel: .air75V3)

        XCTAssertFalse(state.keyboardProfileAllowsEditing)
        XCTAssertTrue(state.settingsFailed)
        XCTAssertEqual(try profiles.load(for: .air75V3), v3)
        XCTAssertEqual(try profiles.load(for: .air75V2), .default)

        try selectionSnapshot.save(KeyboardSelectionSnapshot(
            desiredModel: .air75V2,
            activeModel: .air75V2,
            inventory: [
                KeyboardInventoryEntry(model: .air75V3, count: 1),
                KeyboardInventoryEntry(model: .air75V2, count: 1),
            ],
            phase: .applied
        ))
        health.keyboard = .connected(protocolHealthy: true, model: .air75V2)
        state.refresh()

        XCTAssertEqual(state.profileModel, .air75V2)
        XCTAssertEqual(state.snapshot.profile, .default)
        XCTAssertTrue(state.keyboardProfileAllowsEditing)

        let v2BeforeOldCallback = try Data(contentsOf: profiles.url(for: .air75V2))
        let v3BeforeOldCallback = try Data(contentsOf: profiles.url(for: .air75V3))
        state.updateAppearance(LocalProfile.default.attention, for: LightingPreset.execution, expectedModel: .air75V3)
        XCTAssertTrue(state.settingsFailed, "A delayed V3 edit must be rejected after V2 is applied")
        XCTAssertEqual(try Data(contentsOf: profiles.url(for: .air75V2)), v2BeforeOldCallback)
        XCTAssertEqual(try Data(contentsOf: profiles.url(for: .air75V3)), v3BeforeOldCallback)

        health.keyboard = .connected(protocolHealthy: false, model: .air75V2)
        state.refresh()
        XCTAssertTrue(state.keyboardProfileAllowsEditing, "An unsupported profile must remain repairable")
        XCTAssertFalse(state.keyboardSelectionAllowsPreview)
        try Data("corrupt profile".utf8).write(to: profiles.url(for: .air75V2))
        state.refresh()
        XCTAssertTrue(state.validationFailed)
        XCTAssertEqual(state.profileModel, .air75V2)
        XCTAssertEqual(state.snapshot.profile, .default)
        XCTAssertTrue(state.keyboardProfileAllowsEditing, "The known target may repair a corrupt profile from defaults")
        let v2Execution = SignalAppearance(
            isVisible: true,
            backlight: ZoneAppearance(
                effect: .backlightStatic,
                color: SignalColor(red: 1, green: 2, blue: 3)
            ),
            strip: LocalProfile.default.execution.strip
        )
        state.updateAppearance(v2Execution, for: LightingPreset.execution, expectedModel: .air75V2)

        XCTAssertEqual(try profiles.load(for: .air75V2).execution, v2Execution)
        XCTAssertEqual(try profiles.load(for: .air75V3), v3)
        XCTAssertFalse(state.settingsFailed)
        XCTAssertFalse(state.validationFailed)

        let v2BeforeStaleEdit = try Data(contentsOf: profiles.url(for: .air75V2))
        try selectionSnapshot.save(KeyboardSelectionSnapshot(
            desiredModel: .air75V2, activeModel: .air75V2,
            inventory: [KeyboardInventoryEntry(model: .air75V2, count: 1)],
            phase: .applied, observedAt: .milliseconds(0)
        ))
        // Do not refresh the UI first: the write itself must reject an expired disk snapshot.
        state.updateAppearance(LocalProfile.default.completion, for: LightingPreset.execution, expectedModel: .air75V2)
        XCTAssertTrue(state.settingsFailed)
        XCTAssertEqual(try Data(contentsOf: profiles.url(for: .air75V2)), v2BeforeStaleEdit)
        XCTAssertEqual(try Data(contentsOf: profiles.url(for: .air75V3)), v3BeforeOldCallback)
        state.refresh()
        XCTAssertFalse(state.keyboardProfileAllowsEditing)
    }

    func testDisconnectedKeyboardDoesNotQueueSelectedSignalPreview() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignalPreviewStore(url: directory.appending(path: "preview.json"))
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(), profiles: AppProfile(), durableStatus: AppDurableStatus(),
                lighting: AppLighting(), runtime: AppRecordingRuntime()
            ),
            previewStore: store
        )
        state.beginSignalPreview(for: .attention)
        XCTAssertNil(try store.load())
    }

    func testEditingAnExpiredPresetRenewsItsTargetBoundPhysicalPreview() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = KeyboardProfileStore(directory: directory.appending(path: "profiles"))
        let selection = KeyboardSelectionStore(url: directory.appending(path: "selection.json"))
        let snapshots = KeyboardSelectionSnapshotStore(url: directory.appending(path: "selection-snapshot.json"))
        let preview = SignalPreviewStore(url: directory.appending(path: "preview.json"))
        let status = DurableStatusStore(url: directory.appending(path: "status.json"))
        try profiles.save(.default, for: .air75V2)
        try selection.save(.air75V2)
        try snapshots.save(KeyboardSelectionSnapshot(desiredModel: .air75V2, activeModel: .air75V2,
            inventory: [KeyboardInventoryEntry(model: .air75V2, count: 1)], phase: .applied))
        try status.recordSignal(ownerID: SignalOwnerID(product: "codex", sessionID: "preview-edit", agentID: "main"),
            turnID: "turn", signal: .execution, expiresAt: .milliseconds(100_000),
            replacingSession: true, lockBudget: .milliseconds(100))
        let health = AppMutableHealth(.connected(protocolHealthy: true, model: .air75V2))
        let state = KeyphoreAppState(lifecycle: KeyphoreLifecycle(
            health: health, profiles: AppProfile(), durableStatus: AppDurableStatus(outcome: .execution),
            lighting: AppLighting(), runtime: AppRecordingRuntime()), keyboardProfileStore: profiles,
            previewStore: preview, keyboardSelectionStore: selection, keyboardSelectionSnapshotStore: snapshots)
        let lighting = AppPreviewLighting()
        let companion = KeyphoreCompanion(store: status,
            profileProvider: { try profiles.load(for: XCTUnwrap($0)) }, lighting: lighting,
            previewStore: preview,
            ownershipStore: LightingOwnershipStore(url: directory.appending(path: "ownership.json")),
            selectionStore: selection)
        try companion.sync(at: .milliseconds(0))
        state.beginSignalPreview(for: .completion)
        let first = try XCTUnwrap(preview.load())
        try companion.sync(at: .milliseconds(100))
        let started = try XCTUnwrap(preview.load()?.stageStartedAt).millisecondsSince1970
        try companion.sync(at: .milliseconds(started + 6_000))
        XCTAssertEqual(try preview.load()?.phase, .completed)
        XCTAssertEqual(lighting.behaviors.last, .signal(LocalProfile.default.execution))

        let edited = LocalProfile.default.completion.replacingAppearance(ZoneAppearance(
            effect: .backlightStatic, color: SignalColor(red: 255, green: 109, blue: 30)), for: .backlight)
        state.updateAppearance(edited, for: LightingPreset.completion, expectedModel: .air75V2)
        XCTAssertEqual(try profiles.load(for: .air75V2).completion, edited)
        let renewed = try XCTUnwrap(preview.load())
        XCTAssertNotEqual(renewed.id, first.id)
        XCTAssertEqual(renewed.phase, .pending)
        XCTAssertEqual(renewed.requestedPreset, .completion)
        XCTAssertEqual(renewed.targetModel, .air75V2)
        try companion.sync(at: .milliseconds(started + 6_100))
        XCTAssertEqual(lighting.behaviors.last, .signal(edited), "The edit must override live execution during its preview")
        XCTAssertEqual(try preview.load()?.phase, .presenting)
        let restarted = try XCTUnwrap(preview.load()?.stageStartedAt).millisecondsSince1970
        try companion.sync(at: .milliseconds(restarted + 6_000))
        XCTAssertEqual(lighting.behaviors.last, .signal(LocalProfile.default.execution))
        XCTAssertEqual(try preview.load()?.phase, .completed)

        let completed = try XCTUnwrap(preview.load())
        let savedProfile = try Data(contentsOf: profiles.url(for: .air75V2))
        try snapshots.save(KeyboardSelectionSnapshot(desiredModel: .air75V2, activeModel: .air75V2,
            inventory: [.init(model: .air75V2, count: 1)], phase: .applied, observedAt: .milliseconds(0)))
        state.updateAppearance(.init(isVisible: false, backlight: edited.backlight, strip: edited.strip),
                               for: LightingPreset.completion, expectedModel: .air75V2)
        XCTAssertTrue(state.settingsFailed)
        XCTAssertEqual(try Data(contentsOf: profiles.url(for: .air75V2)), savedProfile)
        XCTAssertEqual(try preview.load()?.id, completed.id, "A refused save must not renew preview")

        // The target may change after the save but before the preview entry refreshes its state.
        XCTAssertFalse(state.requestKeyboardSelection(.air75V3), "A stale inventory cannot authorize a target switch")
        XCTAssertEqual(try selection.load(), .air75V2)
        try snapshots.save(KeyboardSelectionSnapshot(desiredModel: .air75V2, activeModel: .air75V2,
            inventory: [.init(model: .air75V2, count: 1), .init(model: .air75V3, count: 1)], phase: .applied))
        XCTAssertTrue(state.requestKeyboardSelection(.air75V3))
        XCTAssertEqual(try selection.load(), .air75V3)
        try snapshots.save(KeyboardSelectionSnapshot(desiredModel: .air75V3, activeModel: .air75V3,
            inventory: [.init(model: .air75V3, count: 1)], phase: .applied))
        health.keyboard = .connected(protocolHealthy: true, model: .air75V3)
        state.beginSignalPreview(for: .completion, expectedModel: .air75V2)
        XCTAssertEqual(try preview.load()?.id, completed.id, "A V2 edit must not preview on the refreshed V3 target")
        state.beginSignalPreview(for: .completion)
        XCTAssertEqual(try preview.load()?.targetModel, .air75V3, "A separate explicit V3 preview is still available")
    }

    func testFailedIdleProfileWriteDoesNotPreviewStaleSettingsOrHideTheFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = KeyboardProfileStore(directory: directory.appending(path: "profiles"))
        let selection = KeyboardSelectionStore(url: directory.appending(path: "selection.json"))
        let selectionSnapshot = KeyboardSelectionSnapshotStore(url: directory.appending(path: "selection-snapshot.json"))
        try selectionSnapshot.save(KeyboardSelectionSnapshot(
            desiredModel: nil, activeModel: .air75V3,
            inventory: [KeyboardInventoryEntry(model: .air75V3, count: 1)], phase: .applied
        ))
        let preview = SignalPreviewStore(url: directory.appending(path: "preview.json"))
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(keyboard: .connected(protocolHealthy: true, model: .air75V3)),
                profiles: AppKeyboardProfiles(store: profiles, selection: selectionSnapshot),
                durableStatus: AppDurableStatus(), lighting: AppLighting(), runtime: AppRecordingRuntime()
            ),
            keyboardProfileStore: profiles, previewStore: preview,
            keyboardSelectionStore: selection,
            keyboardSelectionSnapshotStore: selectionSnapshot
        )
        try Data("block profile directory".utf8).write(to: profiles.directory)
        let idle = SignalAppearance(
            isVisible: true, backlight: LocalProfile.defaultIdle.backlight,
            strip: LocalProfile.defaultIdle.strip
        )

        state.updateAppearance(idle, for: LightingPreset.idle, expectedModel: .air75V3)

        XCTAssertTrue(state.settingsFailed)
        XCTAssertNil(try preview.load())
        XCTAssertEqual(state.snapshot.profile, .default)
        for preset in [LightingPreset.execution, .attention, .completion] {
            state.updateAppearance(LocalProfile.default.appearance(forPreset: preset),
                                   for: preset, expectedModel: .air75V3)
            XCTAssertTrue(state.settingsFailed)
            XCTAssertNil(try preview.load(), "A failed save must not preview any preset")
        }

        XCTAssertFalse(state.updateControlledZones(.both, expectedModel: .air75V3))
        XCTAssertTrue(state.settingsFailed)
        XCTAssertNil(try preview.load())
    }

    func testStatusPollingDoesNotRepeatInstallationInspectionWithinOneMinute() async {
        let integration = AppSetupIntegration(configured: true)
        let setup = GuidedSetup(hosts: AppHostDetector(), integration: integration,
                                keyboard: AppKeyboardHealth())
        let state = makeState(runtime: AppRecordingRuntime(), guidedSetup: setup)
        let initialChecks = integration.healthChecks
        let now = ContinuousClock.now
        for second in 0..<10 {
            state.refreshDurableStatus(at: now + .seconds(second))
            await state.waitForSetupInspection()
        }
        XCTAssertEqual(integration.healthChecks, initialChecks)
        state.refreshDurableStatus(at: now + .seconds(61))
        await state.waitForSetupInspection()
        XCTAssertEqual(integration.healthChecks, initialChecks + 1)
    }

    func testQuitDoesNotRaceConfigurationOrMigration() async {
        for migration in [false, true] {
            let runtime = AppRecordingRuntime()
            let setup = GuidedSetup(hosts: AppHostDetector(), integration: AppSetupIntegration(),
                                    keyboard: AppKeyboardHealth())
            let state = makeState(runtime: runtime, guidedSetup: setup)
            if migration { state.migrateLegacyAfterReview() } else { state.configureAfterReview() }
            XCTAssertTrue(state.setupIsWorking)
            XCTAssertFalse(state.prepareToQuit())
            XCTAssertTrue(runtime.actions.isEmpty)
            while state.setupIsWorking { await Task.yield() }
            XCTAssertTrue(state.prepareToQuit())
        }
    }

    func testQuitDoesNotRaceRemoval() async {
        let runtime = AppRecordingRuntime()
        let state = makeState(runtime: runtime,
                              managedRemoval: ManagedRemoval(integration: AppManagedRemovalIntegration()))
        state.confirmManagedRemoval()
        XCTAssertTrue(state.removalIsWorking)
        XCTAssertFalse(state.prepareToQuit())
        XCTAssertTrue(runtime.actions.isEmpty)
        while state.removalIsWorking { await Task.yield() }
        XCTAssertTrue(state.prepareToQuit())
    }

    func testExplicitReopenShowsKeySettingsWindowAndReopensItAfterClosing() async throws {
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        XCTAssertTrue(application.setActivationPolicy(.accessory), "Match the menu-bar App's activation policy")
        if !NSRunningApplication.current.isFinishedLaunching { application.finishLaunching() }
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        let runtime = AppRecordingRuntime()
        let delegate = KeyphoreAppDelegate(state: makeState(runtime: runtime))
        defer {
            for window in application.windows where !existingWindows.contains(ObjectIdentifier(window)) {
                window.close()
            }
            application.setActivationPolicy(previousPolicy)
        }

        XCTAssertFalse(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: false))
        let window = try XCTUnwrap(application.windows.first {
            !existingWindows.contains(ObjectIdentifier($0)) && $0.title == AppCopy.value(.settings)
        }, "An explicit open must create a stable settings window, even without a menu-bar popover anchor")
        for _ in 0..<100 where !window.isKeyWindow {
            while let event = application.nextEvent(matching: .any, until: .distantPast,
                                                    inMode: .default, dequeue: true) {
                application.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.isKeyWindow, "Settings must become key; active=\(application.isActive), policy=\(application.activationPolicy().rawValue)")
        XCTAssertTrue(runtime.actions.isEmpty, "Showing settings must not restart the Companion or change hooks")

        window.close()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: false))
        for _ in 0..<100 where !window.isKeyWindow {
            while let event = application.nextEvent(matching: .any, until: .distantPast,
                                                    inMode: .default, dequeue: true) {
                application.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(window.isVisible, "A closed settings window must be shown again on explicit open")
        XCTAssertTrue(window.isKeyWindow, "Settings must become key; active=\(application.isActive), policy=\(application.activationPolicy().rawValue)")
        XCTAssertEqual(application.windows.filter {
            !existingWindows.contains(ObjectIdentifier($0)) && $0.title == AppCopy.value(.settings)
        }.count, 1, "Reopen should reuse the retained settings window")
        XCTAssertFalse(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: true))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.isKeyWindow, "Settings must become key; active=\(application.isActive), policy=\(application.activationPolicy().rawValue)")
        XCTAssertTrue(runtime.actions.isEmpty)
    }

    func testStatusMenuOpensAboutInSharedSettingsSelection() {
        let state = KeyphoreAppState(environment: ["KEYPHORE_ACCEPTANCE_FIXTURE": "ready"])
        let delegate = KeyphoreAppDelegate(state: state)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title), [
            AppCopy.value(.settings) + "…", AppCopy.value(.aboutMenu), "", AppCopy.value(.quit)
        ])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertTrue(NSApp.sendAction(menu.items[1].action!, to: menu.items[1].target, from: menu.items[1]))
        XCTAssertEqual(state.selectedSettingsTab, .about)
        XCTAssertTrue(NSApp.sendAction(menu.items[0].action!, to: menu.items[0].target, from: menu.items[0]))
        XCTAssertEqual(state.selectedSettingsTab, .about)
        for window in NSApp.windows where window.title == AppCopy.value(.settings) { window.close() }
    }

    func testStartupPresentsLoadingWithoutBlockingTheMainActor() async {
        let started = expectation(description: "Startup inspection began")
        let gate = DispatchSemaphore(value: 0)
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(), profiles: AppProfile(), durableStatus: AppDurableStatus(),
                lighting: AppLighting(), runtime: AppRecordingRuntime()
            ),
            deferSystemStartup: true,
            startupInspection: {
                started.fulfill()
                gate.wait()
                return SystemStartupInspection(
                    setup: GuidedSetupSnapshot(phase: .configured, detectedHosts: [.desktopApp],
                                               hooks: HookDefinition.reviewedRelease),
                    removal: ManagedRemovalSnapshot(status: .reviewRequired), loginLaunchEnabled: false
                )
            }
        )
        XCTAssertTrue(state.isStarting)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(state.isStarting)
        gate.signal()
        await state.waitForStartup()
        XCTAssertFalse(state.isStarting)
        XCTAssertEqual(state.setupSnapshot.phase, .configured)
        XCTAssertFalse(state.loginLaunchEnabled)
    }

    func testStartupFailureLeavesLoadingAndReportsFailure() async {
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(), profiles: AppProfile(), durableStatus: AppDurableStatus(),
                lighting: AppLighting(), runtime: AppRecordingRuntime()
            ),
            deferSystemStartup: true,
            startupInspection: { throw CocoaError(.fileReadUnknown) }
        )
        await state.waitForStartup()
        XCTAssertFalse(state.isStarting)
        XCTAssertTrue(state.setupFailed)
    }

    func testFinishedVisualConfirmationDoesNotExpandTheMainPanel() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignalPreviewStore(url: directory.appending(path: "preview.json"))
        for phase in [SignalPreviewPhase.confirmed, .rejected] {
            var record = try store.begin()
            record.phase = phase
            try store.save(record)
            let state = KeyphoreAppState(
                lifecycle: KeyphoreLifecycle(
                    health: AppHealth(), profiles: AppProfile(), durableStatus: AppDurableStatus(),
                    lighting: AppLighting(), runtime: AppRecordingRuntime()
                ),
                previewStore: store
            )
            let hosting = NSHostingController(rootView: KeyphorePopover(state: state))

            XCTAssertLessThanOrEqual(hosting.sizeThatFits(in: NSSize(width: 392, height: 0)).height, 370)
            XCTAssertEqual(try store.load()?.phase, phase)
        }
    }

    func testGeneralSettingsPersistWithoutStartingDiagnosticCollection() async throws {
        let suite = "keyphore-app-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        let provider = AppDiagnosticProvider(snapshot: DiagnosticSnapshot(
            appVersion: "0.1.0", macOSVersion: "macOS", codexHosts: [],
            integration: .notConfigured, keyboard: .disconnected
        ), onCollection: {})
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(), profiles: AppProfile(), durableStatus: AppDurableStatus(),
                lighting: AppLighting(), runtime: AppRecordingRuntime()
            ),
            diagnosticSnapshotProvider: provider.snapshot,
            preferencesStore: store
        )

        for choice in AppLanguageChoice.allCases where choice != .system {
            state.updatePreferences(AppPreferences(appearance: .dark, language: choice))
            XCTAssertFalse(state.diagnosticReportIsRefreshing)
            XCTAssertFalse(state.diagnosticReportIsReady)
            XCTAssertEqual(provider.callCount, 0)
            XCTAssertEqual(store.load(), state.preferences)
            XCTAssertEqual(state.diagnosticReport.language, choice.language)
            XCTAssertEqual(state.snapshot.profile, .default)
        }
    }

    func testResettingSignalColorPersistsWithoutResettingOtherSignalSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeyboardProfileStore(directory: directory.appending(path: "profiles"))
        let selection = KeyboardSelectionStore(url: directory.appending(path: "selection.json"))
        let selectionSnapshot = KeyboardSelectionSnapshotStore(url: directory.appending(path: "selection-snapshot.json"))
        try selectionSnapshot.save(KeyboardSelectionSnapshot(
            desiredModel: nil, activeModel: .air75V3,
            inventory: [KeyboardInventoryEntry(model: .air75V3, count: 1)], phase: .applied
        ))
        let preview = SignalPreviewStore(url: directory.appending(path: "preview.json"))
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(keyboard: .connected(protocolHealthy: true, model: .air75V3)),
                profiles: AppKeyboardProfiles(store: store, selection: selectionSnapshot),
                durableStatus: AppDurableStatus(), lighting: AppLighting(), runtime: AppRecordingRuntime()
            ),
            keyboardProfileStore: store, previewStore: preview,
            keyboardSelectionStore: selection,
            keyboardSelectionSnapshotStore: selectionSnapshot
        )
        let custom = SignalAppearance(
            isVisible: false,
            backlight: ZoneAppearance(
                effect: .backlightWave, color: SignalColor(red: 120, green: 30, blue: 90),
                colorMode: .multicolor, brightness: SignalBrightness(percent: 42)!,
                speed: LightingSpeed(level: 4)!, direction: .reverse
            ),
            strip: LocalProfile.default.completion.strip
        )
        let customIdle = SignalAppearance(
            isVisible: true, backlight: LocalProfile.defaultIdle.backlight,
            strip: LocalProfile.defaultIdle.strip
        )
        state.updateControlledZones(.both, expectedModel: .air75V3)
        state.updateAppearance(customIdle, for: LightingPreset.idle, expectedModel: .air75V3)
        state.updateAppearance(custom, for: CodexSignal.completion, expectedModel: .air75V3)
        state.updateCompletionDisplayDuration(
            CompletionDisplayDuration(seconds: 12)!, expectedModel: .air75V3
        )
        let beforeReset = try XCTUnwrap(preview.load())
        XCTAssertEqual(beforeReset.requestedPreset, .completion, "The CodexSignal overload must use the shared preview path")
        state.resetSignalColor(for: .completion, zone: .backlight, expectedModel: .air75V3)
        XCTAssertNotEqual(try preview.load()?.id, beforeReset.id)
        XCTAssertEqual(try preview.load()?.requestedPreset, .completion)
        XCTAssertEqual(try preview.load()?.targetModel, .air75V3)

        let reopened = try store.load(for: .air75V3)
        XCTAssertEqual(reopened.completion.backlight.color, LocalProfile.default.completion.backlight.color)
        XCTAssertEqual(reopened.completion.backlight.brightness.percent, 42)
        XCTAssertEqual(reopened.completion.backlight.effect, .backlightWave)
        XCTAssertEqual(reopened.completion.backlight.colorMode, .custom)
        XCTAssertEqual(reopened.completion.backlight.speed.level, 4)
        XCTAssertEqual(reopened.completion.backlight.direction, .reverse)
        XCTAssertFalse(reopened.completion.isVisible)
        XCTAssertEqual(reopened.completionDisplayDuration.seconds, 12)
        XCTAssertEqual(reopened.controlledZones, .both)
        XCTAssertEqual(reopened.idle, customIdle)
        XCTAssertEqual(reopened.execution, LocalProfile.default.execution)
        XCTAssertEqual(reopened.attention, LocalProfile.default.attention)
        XCTAssertEqual(state.snapshot.profile, reopened)
    }

    func testAppStateCollectsTheReviewedDiagnosticPreviewOnlyWhenRequested() async {
        let diagnosticSnapshot = DiagnosticSnapshot(
            appVersion: "0.1.0 (1)",
            macOSVersion: "macOS 15.6.1",
            codexHosts: [.desktopApp],
            integration: .notConfigured,
            keyboard: .disconnected
        )
        let collected = expectation(description: "diagnostics collected")
        let provider = AppDiagnosticProvider(snapshot: diagnosticSnapshot) {
            collected.fulfill()
        }
        let state = KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(),
                profiles: AppProfile(),
                durableStatus: AppDurableStatus(),
                lighting: AppLighting(),
                runtime: AppRecordingRuntime()
            ),
            diagnosticSnapshotProvider: provider.snapshot,
            diagnosticLanguage: .english
        )

        XCTAssertEqual(provider.callCount, 0)
        XCTAssertFalse(state.diagnosticReportIsReady)

        state.refresh()

        XCTAssertEqual(provider.callCount, 0)

        state.refreshDiagnosticReport()
        XCTAssertTrue(state.diagnosticReportIsRefreshing)
        await fulfillment(of: [collected], timeout: 1)
        while state.diagnosticReport.fields.first?.value != "0.1.0 (1)" {
            await Task.yield()
        }

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertTrue(state.diagnosticReportIsReady)
        XCTAssertFalse(state.diagnosticReportIsRefreshing)
        XCTAssertEqual(state.diagnosticReport.fields.map(\.id), DiagnosticField.ID.allCases)
        XCTAssertEqual(state.diagnosticReport.language, .english)
    }

    func testQuitBlocksCachedHooksAndReopensThroughAppLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "keyphore-app-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = QuitGateStore(url: directory.appending(path: "quit-gate"))
        let runtime = AppRecordingRuntime(gate: gate)
        let state = makeState(runtime: runtime)
        let delegate = KeyphoreAppDelegate(state: state)
        delegate.prepareToQuit = state.prepareToQuit

        XCTAssertEqual(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared), false)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateNow)
        XCTAssertEqual(runtime.actions, [.activateGate, .disableHooks, .clearState, .signalOff, .stop])

        let statusURL = directory.appending(path: "status.json")
        try ProductionHookHandler(
            store: DurableStatusStore(url: statusURL),
            quitGate: gate
        ).handle(Data(
            #"{"hook_event_name":"UserPromptSubmit","session_id":"cached","turn_id":"turn-1"}"#.utf8
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusURL.path))

        XCTAssertEqual(try state.reopenIfNeeded(), .restored)
        XCTAssertEqual(
            Array(runtime.actions.suffix(5)),
            [.clearState, .enableTrustedHooks, .start, .signalOff, .clearGate]
        )
    }

    func testLoginLaunchSettingUsesTheAppStateSeam() {
        let integration = AppSetupIntegration()
        let setup = GuidedSetup(
            hosts: AppHostDetector(),
            integration: integration,
            keyboard: AppKeyboardHealth()
        )
        let state = makeState(runtime: AppRecordingRuntime(), guidedSetup: setup)

        state.updateLoginLaunch(false)

        XCTAssertFalse(state.loginLaunchEnabled)
        XCTAssertEqual(integration.loginLaunchSelections, [false])
    }

    func testChangedHookUpdatePreparationUsesQuitGateAndCanRecoverTrustedHooks() throws {
        let runtime = AppRecordingRuntime()
        let state = makeState(runtime: runtime)

        try state.prepareForChangedHookUpdate()

        XCTAssertTrue(runtime.isQuitGateActive)
        XCTAssertEqual(runtime.actions, [.activateGate, .disableHooks])

        try state.recoverFromFailedChangedHookUpdate()

        XCTAssertFalse(runtime.isQuitGateActive)
        XCTAssertEqual(
            runtime.actions,
            [.activateGate, .disableHooks, .enableTrustedHooks, .clearGate]
        )
    }

    func testAppStateRequiresConfirmationThenCompletesManagedRemoval() async {
        let integration = AppManagedRemovalIntegration()
        let state = makeState(
            runtime: AppRecordingRuntime(),
            managedRemoval: ManagedRemoval(integration: integration)
        )

        state.presentManagedRemoval()

        XCTAssertTrue(state.removalIsPresented)
        XCTAssertEqual(state.removalSnapshot.components, Set(ManagedRemovalComponent.allCases))
        XCTAssertTrue(integration.actions.isEmpty)

        state.confirmManagedRemoval()
        while state.removalIsWorking {
            await Task.yield()
        }

        XCTAssertEqual(state.removalSnapshot.status, .completed)
        XCTAssertFalse(state.removalFailed)
        XCTAssertEqual(integration.actions.first, .begin)
        XCTAssertEqual(integration.actions.last, .complete)
        XCTAssertTrue(state.prepareToQuit())
    }

    func testInterruptedManagedRemovalIsPresentedForRepairOnLaunch() {
        let integration = AppManagedRemovalIntegration(status: .repairRequired)

        let state = makeState(
            runtime: AppRecordingRuntime(),
            managedRemoval: ManagedRemoval(integration: integration)
        )

        XCTAssertTrue(state.removalIsPresented)
        XCTAssertEqual(state.removalSnapshot.status, .repairRequired)
    }

    func testManagedRemovalFinishDismissesTheSheetBeforeRequestingTermination() async {
        var events: [String] = []
        let action = ManagedRemovalFinishAction {
            events.append("terminate")
        }

        action.perform {
            events.append("dismiss")
        }

        XCTAssertEqual(events, ["dismiss"])
        await Task.yield()
        XCTAssertEqual(events, ["dismiss", "terminate"])
    }

    private func makeState(
        runtime: AppRecordingRuntime,
        guidedSetup: GuidedSetup? = nil,
        managedRemoval: ManagedRemoval? = nil
    ) -> KeyphoreAppState {
        KeyphoreAppState(
            lifecycle: KeyphoreLifecycle(
                health: AppHealth(),
                profiles: AppProfile(),
                durableStatus: AppDurableStatus(),
                lighting: AppLighting(),
                runtime: runtime
            ),
            guidedSetup: guidedSetup,
            managedRemoval: managedRemoval,
            updateRuntime: runtime
        )
    }
}

@MainActor
private final class KeyboardMenuFixture {
    let directory: URL
    let selection: KeyboardSelectionStore
    let snapshots: KeyboardSelectionSnapshotStore
    let preview: SignalPreviewStore
    let health: AppMutableHealth
    let state: KeyphoreAppState

    init(desired: SupportedKeyboardModel? = nil, active: SupportedKeyboardModel? = .air75V3,
         inventory: [KeyboardInventoryEntry] = [.init(model: .air75V3, count: 1), .init(model: .air75V2, count: 1)],
         configured: Bool = true, starting: Bool = false) throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        selection = KeyboardSelectionStore(url: directory.appending(path: "selection.json"))
        snapshots = KeyboardSelectionSnapshotStore(url: directory.appending(path: "snapshot.json"))
        preview = SignalPreviewStore(url: directory.appending(path: "preview.json"))
        let profiles = KeyboardProfileStore(directory: directory.appending(path: "profiles"))
        try selection.save(desired)
        try snapshots.save(KeyboardSelectionSnapshot(desiredModel: desired, activeModel: active,
            inventory: inventory, phase: active == nil ? .blocked : .applied, failure: active == nil ? .ambiguous : nil))
        health = AppMutableHealth(active.map { .connected(protocolHealthy: true, model: $0) } ?? .ambiguous)
        health.isConfigured = configured
        state = KeyphoreAppState(lifecycle: KeyphoreLifecycle(health: health, profiles: AppKeyboardProfiles(store: profiles, selection: snapshots),
            durableStatus: AppDurableStatus(), lighting: AppLighting(), runtime: AppRecordingRuntime()),
            keyboardProfileStore: profiles, previewStore: preview,
            keyboardSelectionStore: selection, keyboardSelectionSnapshotStore: snapshots,
            deferSystemStartup: starting, startupInspection: { throw CocoaError(.fileReadUnknown) },
            preferencesStore: AppPreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private final class AppDiagnosticProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let diagnosticSnapshot: DiagnosticSnapshot
    private let onCollection: @Sendable () -> Void
    private var calls = 0

    init(snapshot: DiagnosticSnapshot, onCollection: @escaping @Sendable () -> Void) {
        diagnosticSnapshot = snapshot
        self.onCollection = onCollection
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func snapshot() -> DiagnosticSnapshot {
        lock.withLock { calls += 1 }
        onCollection()
        return diagnosticSnapshot
    }
}

private final class AppRecordingRuntime: KeyphoreRuntimeManaging {
    enum Action: Equatable {
        case activateGate, disableHooks, clearState, signalOff, stop
        case start, enableTrustedHooks, clearGate
    }

    private let gate: QuitGateStore
    private(set) var actions: [Action] = []

    init(gate: QuitGateStore = QuitGateStore(
        url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    )) {
        self.gate = gate
    }

    var isQuitGateActive: Bool { gate.isActive }
    func activateQuitGate() throws { try gate.activate(); actions.append(.activateGate) }
    func disableOwnedHooks() { actions.append(.disableHooks) }
    func stopCompanion() { actions.append(.stop) }
    func clearManagedRuntimeState() { actions.append(.clearState) }
    func requestSignalOff() { actions.append(.signalOff) }
    func enableOwnedHooksIfTrusted() -> Bool { actions.append(.enableTrustedHooks); return true }
    func startCompanion() { actions.append(.start) }
    func clearQuitGate() throws { try gate.clear(); actions.append(.clearGate) }
}

private struct AppHealth: KeyphoreHealthProviding {
    var keyboard: KeyboardHealth = .disconnected
    func currentHealth() -> KeyphoreHealth { .configured(keyboard: keyboard) }
}

private final class AppMutableHealth: KeyphoreHealthProviding {
    var keyboard: KeyboardHealth
    var isConfigured = true
    init(_ keyboard: KeyboardHealth) { self.keyboard = keyboard }
    func currentHealth() -> KeyphoreHealth { KeyphoreHealth(isConfigured: isConfigured, keyboard: keyboard) }
}

private struct AppProfile: LocalProfileProviding {
    func currentProfile() -> LocalProfile { .default }
}

private struct AppKeyboardProfiles: LocalProfileProviding {
    let store: KeyboardProfileStore
    let selection: KeyboardSelectionSnapshotStore
    func currentProfile() -> LocalProfile {
        guard let snapshot = selection.load(), snapshot.phase == .applied,
              let model = snapshot.activeModel else { return .default }
        return (try? store.load(for: model)) ?? .default
    }
}

private struct AppDurableStatus: DurableStatusProviding {
    var outcome: DurableStatusOutcome = .signalOff
    func currentOutcome() -> DurableStatusOutcome { outcome }
}

private final class AppLighting: LightingEmitting {
    func emit(_ behavior: LightingBehavior) {}
}

private struct AppHostDetector: CodexHostDetecting {
    func detectHosts() -> Set<CodexHost> { [.desktopApp] }
}

private struct AppKeyboardHealth: SetupKeyboardHealthProviding {
    func currentKeyboardHealth() -> KeyboardHealth { .disconnected }
}

private final class AppSetupIntegration: GuidedSetupIntegrating {
    let configured: Bool
    private(set) var healthChecks = 0
    private(set) var loginLaunchSelections: [Bool] = []
    private var loginLaunch = true

    init(configured: Bool = false) { self.configured = configured }
    func health() -> SetupIntegrationHealth {
        healthChecks += 1
        return configured ? SetupIntegrationHealth(pluginInstalled: true, hooksTrusted: true,
                                                   companionRegistered: true, managedStatePresent: true) : .notConfigured
    }
    func stage(_ hooks: [HookDefinition]) {}
    func installedHookHashes() -> [HookEvent: String] { HookDefinition.reviewedHashes }
    func trust(_ hooks: [HookDefinition]) {}
    func resetRuntimeState() {}
    func registerCompanion() {}
    func persistConfigured() {}
    func setLoginLaunchEnabled(_ enabled: Bool) {
        loginLaunch = enabled
        loginLaunchSelections.append(enabled)
    }
    func loginLaunchEnabled() -> Bool { loginLaunch }
}

private final class AppManagedRemovalIntegration: ManagedRemovalIntegrating {
    enum Action: Equatable { case begin, signalOff, disableHooks, companion, plugin, state, verify, complete }

    private(set) var actions: [Action] = []
    private var status: ManagedRemovalStatus

    init(status: ManagedRemovalStatus = .reviewRequired) {
        self.status = status
    }

    func inspectManagedRemoval() -> ManagedRemovalStatus { status }
    func beginManagedRemoval() { actions.append(.begin); status = .repairRequired }
    func requestSignalOffForRemoval() { actions.append(.signalOff) }
    func disableOwnedHooksForRemoval() { actions.append(.disableHooks) }
    func removeCompanionAndBackgroundRegistration() { actions.append(.companion) }
    func removePluginAndHooks() { actions.append(.plugin) }
    func removeLocalProfileAndManagedRuntimeState() { actions.append(.state) }
    func verifyManagedRemoval() -> Bool { actions.append(.verify); return true }
    func completeManagedRemoval() { actions.append(.complete); status = .completed }
}

private final class AppPreviewLighting: CompanionLightingEvidenceApplying, CompanionKeyboardSelecting {
    var connectedModel: SupportedKeyboardModel?
    var behaviors: [LightingBehavior] = []
    func keyboardInventory() -> [KeyboardInventoryEntry] { [.init(model: .air75V2, count: 1)] }
    func selectTarget(_ model: SupportedKeyboardModel?) { connectedModel = model }
    func apply(_ behavior: LightingBehavior) throws { _ = try applyAndVerify(behavior) }
    func applyAndVerify(_ behavior: LightingBehavior) throws -> NuPhyIOEvidence {
        behaviors.append(behavior)
        return NuPhyIOEvidence(protocolReadbackSucceeded: true, visualConfirmation: .notRequested,
                               mainState: [], rhythmBefore: [], rhythmAfter: [])
    }
}
