import XCTest
import KeyphoreCore

@MainActor
final class GuidedSetupAcceptanceTests: XCTestCase {
    func testDiagnosticSnapshotUsesOnlyReviewedHealthFacts() throws {
        let health = SetupIntegrationHealth(
            pluginInstalled: true,
            hooksTrusted: false,
            companionRegistered: true,
            managedStatePresent: true
        )
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([.desktopApp]),
            integration: RecordingSetupIntegration(health: health),
            keyboard: FixedSetupKeyboard(.connected(protocolHealthy: false))
        )

        let snapshot = setup.diagnosticSnapshot(
            appVersion: "0.1.0 (1)",
            macOSVersion: "macOS 15.6.1"
        )

        XCTAssertEqual(snapshot.codexHosts, [.desktopApp])
        XCTAssertEqual(snapshot.integration, health)
        XCTAssertEqual(snapshot.keyboard, .connected(protocolHealthy: false))
        XCTAssertFalse(snapshot.collectionFailed)
    }

    func testAppServerMetadataDecodesThePluginIdField() throws {
        let data = Data(
            """
            {
              "key": "keyphore@keyphore-app:hooks/hooks.json:session_start:0:0",
              "eventName": "sessionStart",
              "handlerType": "command",
              "executionMode": "sync",
              "matcher": null,
              "command": "\\\"/plugin/bin/keyphore\\\" hook",
              "timeoutSec": 1,
              "statusMessage": null,
              "additionalContextLimit": null,
              "sourcePath": "/plugin/hooks/hooks.json",
              "pluginId": "keyphore@keyphore-app",
              "enabled": true,
              "isManaged": false,
              "currentHash": "sha256:reviewed",
              "trustStatus": "trusted"
            }
            """.utf8
        )

        let metadata = try JSONDecoder().decode(CodexHookMetadata.self, from: data)

        XCTAssertEqual(metadata.pluginID, "keyphore@keyphore-app")
        XCTAssertEqual(metadata.event, .sessionStart)
    }

    func testRuntimeSelectionPrefersCLIWhenBothHostsAreInstalled() {
        let cli = URL(fileURLWithPath: "/usr/local/bin/codex")
        let desktop = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")

        XCTAssertEqual(
            CodexRuntimeCompatibility.preferredURL(commandLine: cli, desktop: desktop),
            cli
        )
    }

    func testAppServerUsesTheDefaultStdioTransportAcceptedByBothHosts() {
        XCTAssertEqual(CodexRuntimeCompatibility.appServerArguments, ["app-server"])
    }

    func testHookReviewMatchesTheEightReleaseDefinitionsAndPrivacyBoundary() {
        let hooks = HookDefinition.reviewedRelease

        XCTAssertEqual(hooks.map(\.event.rawValue), [
            "PermissionRequest",
            "PostToolUse",
            "SessionEnd",
            "SessionStart",
            "Stop",
            "SubagentStart",
            "SubagentStop",
            "UserPromptSubmit",
        ])
        XCTAssertEqual(hooks.map(\.reviewedHash), [
            "sha256:5f25dca9d0ce796a5c7169e57b0fd97b90af4a3fe4329fba791a35aff00fd321",
            "sha256:7cc58a7a6b7d62914e65120af0b388a61824fa237d8bcdff2d0e8f2f86dcd49f",
            "sha256:45290ede59950ec464758a3b5f3aca05bc0184a0f456a2dee6f2ca87a65334c9",
            "sha256:8d0997952af595e40966d18a4b970ddfde9b1082c99d154374e209c4723d9b75",
            "sha256:e20bbf3639086f8545a28998eac049fba54d63f8fb0b5876e0b43d6f1f0cd34d",
            "sha256:01946b08cd49609fe0cc4a8e43959cd3ebf29ab011278f51d9f77abdbd032a98",
            "sha256:36375c4c50d15317921135227d6c423f134853c725df334433a38f47fe918c40",
            "sha256:af395f0d95e15ee1a97f0437eedb1859cdea89b94225d88ba706619e661b9a20",
        ])
        XCTAssertEqual(hooks[0].allowedFields, [.event, .session, .agent, .turn, .receivedAt])
        XCTAssertEqual(hooks[2].allowedFields, [.event, .session, .receivedAt])
        XCTAssertEqual(hooks[4].allowedFields, [.event, .session, .turn, .receivedAt])
        XCTAssertTrue(hooks.allSatisfy { $0.command == "\"${PLUGIN_ROOT}/bin/keyphore\" hook" })
        XCTAssertTrue(hooks.allSatisfy { $0.timeoutSeconds == 1 })
        XCTAssertFalse(HookField.allCases.map(\.rawValue).contains("prompt"))
        XCTAssertFalse(HookField.allCases.map(\.rawValue).contains("tool_response"))
        XCTAssertFalse(HookField.allCases.map(\.rawValue).contains("transcript_path"))
    }

    func testHookInputProjectsAwayPrivateContentBeforeRuntimeUse() throws {
        let privateValues = [
            "private prompt",
            "private response prose",
            "/private/transcript.jsonl",
            "private tool output",
        ]
        let input: [String: Any] = [
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-1",
            "agent_id": "agent-1",
            "turn_id": "turn-1",
            "prompt": privateValues[0],
            "last_assistant_message": privateValues[1],
            "transcript_path": privateValues[2],
            "tool_response": privateValues[3],
        ]

        let record = try PrivacyAllowedHookRecord(
            jsonData: JSONSerialization.data(withJSONObject: input),
            receivedAt: "2026-08-31T12:00:00Z"
        )
        let persisted = String(decoding: try record.encoded(), as: UTF8.self)

        for privateValue in privateValues {
            XCTAssertFalse(persisted.contains(privateValue))
        }
        XCTAssertTrue(persisted.contains("UserPromptSubmit"))
        XCTAssertTrue(persisted.contains("session-1"))
        XCTAssertFalse(persisted.contains("agent-1"))
        XCTAssertTrue(persisted.contains("turn-1"))
        XCTAssertTrue(persisted.contains("2026-08-31T12:00:00Z"))
    }

    func testEachHookInputUsesItsOwnReviewedFieldSet() throws {
        let input: [String: Any] = [
            "hook_event_name": "SessionEnd",
            "session_id": "session-1",
            "agent_id": "must-not-persist",
            "turn_id": "must-not-persist",
        ]

        let record = try PrivacyAllowedHookRecord(
            jsonData: JSONSerialization.data(withJSONObject: input),
            receivedAt: "2026-08-31T12:00:00Z"
        )
        let persisted = String(decoding: try record.encoded(), as: UTF8.self)

        XCTAssertTrue(persisted.contains("SessionEnd"))
        XCTAssertTrue(persisted.contains("session-1"))
        XCTAssertFalse(persisted.contains("must-not-persist"))
    }

    func testConsentDigestChangesWhenTheReviewedPrivacyBoundaryChanges() {
        var changed = HookDefinition.reviewedRelease
        let original = changed[7]
        changed[7] = HookDefinition(
            event: original.event,
            allowedFields: original.allowedFields.union([.agent]),
            reviewedHash: original.reviewedHash,
            command: original.command,
            timeoutSeconds: original.timeoutSeconds
        )

        XCTAssertNotEqual(
            HookDefinition.digest(for: changed),
            HookDefinition.reviewedReleaseDigest
        )
    }

    func testEitherCodexHostReachesHookReviewWithoutChangingIntegration() throws {
        for hosts in [Set([CodexHost.desktopApp]), Set([CodexHost.commandLine])] {
            let integration = RecordingSetupIntegration()
            let setup = GuidedSetup(
                hosts: FixedCodexHostDetector(hosts),
                integration: integration,
                keyboard: FixedSetupKeyboard(.disconnected)
            )

            let snapshot = try setup.inspect()

            XCTAssertEqual(snapshot.phase, .hookReview)
            XCTAssertEqual(snapshot.detectedHosts, hosts)
            XCTAssertEqual(snapshot.hooks, HookDefinition.reviewedRelease)
            XCTAssertEqual(integration.actions, [])
        }
    }

    func testLegacyInstallationRequiresReviewWithoutChangingOwnedComponents() throws {
        let legacy = LegacyMigrationStatus.reviewRequired([
            .plugin,
            .hooks,
            .companionRegistration,
            .managedRuntimeState,
        ])
        let integration = RecordingSetupIntegration(legacyMigrationStatus: legacy)
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([.desktopApp]),
            integration: integration,
            keyboard: FixedSetupKeyboard(.disconnected)
        )

        let snapshot = try setup.inspect()

        XCTAssertEqual(snapshot.phase, .legacyMigrationReview)
        XCTAssertEqual(snapshot.legacyMigrationStatus, legacy)
        XCTAssertEqual(integration.actions, [])
    }

    func testConfirmedLegacyMigrationProvesOldCompanionStoppedBeforeStartingCurrentCompanion() throws {
        let integration = RecordingSetupIntegration(
            legacyMigrationStatus: .reviewRequired(Set(LegacyComponent.allCases))
        )
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([.desktopApp]),
            integration: integration,
            keyboard: FixedSetupKeyboard(.disconnected)
        )

        let migration = try setup.migrateLegacyAfterReview()

        XCTAssertEqual(migration.phase, .hookReview)
        XCTAssertEqual(
            migration.legacyMigrationStatus,
            .awaitingHookConsent(Set(LegacyComponent.allCases))
        )
        XCTAssertEqual(
            integration.actions,
            [
                .beginLegacyMigration,
                .disableLegacyHooks,
                .stopLegacyCompanion,
                .verifyLegacyCompanionStopped,
                .removeLegacyComponents,
                .stage,
                .readHookHashes,
                .resetRuntimeState,
                .completeLegacyMigration,
            ]
        )
        XCTAssertFalse(integration.actions.contains(.trust))
        XCTAssertFalse(integration.actions.contains(.registerCompanion))

        _ = try setup.configureAfterReview()

        XCTAssertEqual(
            integration.actions,
            [
                .beginLegacyMigration,
                .disableLegacyHooks,
                .stopLegacyCompanion,
                .verifyLegacyCompanionStopped,
                .removeLegacyComponents,
                .stage,
                .readHookHashes,
                .resetRuntimeState,
                .completeLegacyMigration,
                .stage,
                .readHookHashes,
                .trust,
                .resetRuntimeState,
                .registerCompanion,
                .persistConfigured,
                .completeLegacyHookConsent,
                .finishConfiguration,
            ]
        )
        let stopProof = try XCTUnwrap(
            integration.actions.firstIndex(of: .verifyLegacyCompanionStopped)
        )
        let currentStart = try XCTUnwrap(integration.actions.firstIndex(of: .registerCompanion))
        XCTAssertLessThan(stopProof, currentStart)
    }

    func testOrdinaryConsentCannotBypassLegacyReviewOrRepair() throws {
        for status in [
            LegacyMigrationStatus.reviewRequired(Set(LegacyComponent.allCases)),
            .repairRequired(Set(LegacyComponent.allCases)),
        ] {
            let integration = RecordingSetupIntegration(legacyMigrationStatus: status)
            let setup = GuidedSetup(
                hosts: FixedCodexHostDetector([.desktopApp]),
                integration: integration,
                keyboard: FixedSetupKeyboard(.disconnected)
            )

            XCTAssertThrowsError(try setup.configureAfterReview()) { error in
                XCTAssertEqual(error as? GuidedSetupError, .legacyMigrationRequired)
            }
            XCTAssertEqual(integration.actions, [])
        }
    }

    func testMigrationRemainsIncompleteUntilSignalPreviewGetsVisualConfirmation() throws {
        let integration = RecordingSetupIntegration(
            legacyMigrationStatus: .reviewRequired(Set(LegacyComponent.allCases))
        )
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([.desktopApp]),
            integration: integration,
            keyboard: FixedSetupKeyboard(.connected(protocolHealthy: true))
        )

        _ = try setup.migrateLegacyAfterReview()
        let configured = try setup.configureAfterReview()

        XCTAssertEqual(
            configured.legacyMigrationStatus,
            .awaitingSignalPreview(Set(LegacyComponent.allCases))
        )
        try setup.completeLegacySignalPreview(.rejected)
        XCTAssertEqual(
            try setup.inspect().legacyMigrationStatus,
            .awaitingSignalPreview(Set(LegacyComponent.allCases))
        )
        XCTAssertNotEqual(integration.actions.last, .completeLegacySignalPreview)

        try setup.completeLegacySignalPreview(.confirmed)
        XCTAssertEqual(try setup.inspect().legacyMigrationStatus, .none)
        XCTAssertEqual(integration.actions.last, .completeLegacySignalPreview)
    }

    func testInterruptedMigrationNeverStartsCurrentCompanionAndReopensAsRepairable() throws {
        let integration = RecordingSetupIntegration(
            legacyMigrationStatus: .reviewRequired(Set(LegacyComponent.allCases)),
            legacyCompanionStops: false
        )
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([.desktopApp]),
            integration: integration,
            keyboard: FixedSetupKeyboard(.disconnected)
        )

        XCTAssertThrowsError(try setup.migrateLegacyAfterReview()) { error in
            XCTAssertEqual(error as? GuidedSetupError, .legacyCompanionStillRunning)
        }
        XCTAssertEqual(
            integration.actions,
            [
                .beginLegacyMigration,
                .disableLegacyHooks,
                .stopLegacyCompanion,
                .verifyLegacyCompanionStopped,
            ]
        )
        XCTAssertFalse(integration.actions.contains(.stage))
        XCTAssertFalse(integration.actions.contains(.registerCompanion))

        let repair = try setup.inspect()
        XCTAssertEqual(repair.phase, .legacyMigrationRepair)
    }

    func testMissingCodexHostIsReportedWithoutChangingIntegration() throws {
        let integration = RecordingSetupIntegration()
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([]),
            integration: integration,
            keyboard: FixedSetupKeyboard(.disconnected)
        )

        let snapshot = try setup.inspect()

        XCTAssertEqual(snapshot.phase, .codexHostMissing)
        XCTAssertEqual(snapshot.detectedHosts, [])
        XCTAssertEqual(integration.actions, [])
    }

    func testConsentConfiguresOnlyTheReviewedHookHashesInOrder() throws {
        let integration = RecordingSetupIntegration()
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([.desktopApp]),
            integration: integration,
            keyboard: FixedSetupKeyboard(.disconnected)
        )

        let snapshot = try setup.configureAfterReview()

        XCTAssertEqual(snapshot.phase, .configured)
        XCTAssertEqual(
            integration.actions,
            [
                .stage,
                .readHookHashes,
                .trust,
                .resetRuntimeState,
                .registerCompanion,
                .persistConfigured,
                .finishConfiguration,
            ]
        )
    }

    func testGuidedSetupAppliesExplicitLoginLaunchChoiceOnlyAfterConfiguration() throws {
        for enabled in [true, false] {
            let integration = RecordingSetupIntegration()
            let setup = GuidedSetup(
                hosts: FixedCodexHostDetector([.desktopApp]),
                integration: integration,
                keyboard: FixedSetupKeyboard(.disconnected)
            )

            _ = try setup.configureAfterReview(loginLaunchEnabled: enabled)

            XCTAssertEqual(
                integration.actions,
                [
                    .stage,
                    .readHookHashes,
                    .trust,
                    .resetRuntimeState,
                    .registerCompanion,
                    .persistConfigured,
                    .finishConfiguration,
                    .setLoginLaunch(enabled),
                ]
            )
        }
    }

    func testChangedHookHashCannotReceiveConsentOrReachConfigured() throws {
        var hashes = Dictionary(
            uniqueKeysWithValues: HookDefinition.reviewedRelease.map { ($0.event, $0.reviewedHash) }
        )
        hashes[.stop] = "sha256:changed"
        let integration = RecordingSetupIntegration(hashes: hashes)
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([.commandLine]),
            integration: integration,
            keyboard: FixedSetupKeyboard(.disconnected)
        )

        XCTAssertThrowsError(try setup.configureAfterReview()) { error in
            XCTAssertEqual(error as? GuidedSetupError, .reviewedHooksChanged)
        }
        XCTAssertEqual(integration.actions, [.stage, .readHookHashes])
    }

    func testChangedManagedReleaseRestagesRuntimeAndRepairsMissingOwnedComponents() throws {
        let integration = RecordingSetupIntegration(
            health: SetupIntegrationHealth(
                pluginInstalled: true,
                hooksTrusted: true,
                companionRegistered: false,
                managedStatePresent: false
            )
        )
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([.desktopApp]),
            integration: integration,
            keyboard: FixedSetupKeyboard(.disconnected)
        )

        let snapshot = try setup.configureAfterReview()

        XCTAssertEqual(snapshot.phase, .configured)
        XCTAssertEqual(
            integration.actions,
            [
                .stage,
                .readHookHashes,
                .resetRuntimeState,
                .registerCompanion,
                .persistConfigured,
                .finishConfiguration,
            ]
        )
        XCTAssertEqual(integration.unrelatedPluginState, "preserved")
    }

    func testChangedManagedReleaseRestartsAnAlreadyRegisteredCompanion() throws {
        let integration = RecordingSetupIntegration(
            health: SetupIntegrationHealth(
                pluginInstalled: true,
                hooksTrusted: true,
                companionRegistered: true,
                managedStatePresent: false
            )
        )
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([.desktopApp]),
            integration: integration,
            keyboard: FixedSetupKeyboard(.disconnected)
        )

        _ = try setup.configureAfterReview()

        XCTAssertEqual(
            integration.actions,
            [
                .stage,
                .readHookHashes,
                .resetRuntimeState,
                .registerCompanion,
                .persistConfigured,
                .finishConfiguration,
            ]
        )
    }

    func testCurrentManagedRuntimePreservesOwnersWhenOnlyCompanionRegistrationIsMissing() throws {
        let integration = RecordingSetupIntegration(
            health: SetupIntegrationHealth(
                pluginInstalled: true,
                hooksTrusted: true,
                companionRegistered: false,
                managedStatePresent: true
            )
        )
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([.desktopApp]),
            integration: integration,
            keyboard: FixedSetupKeyboard(.disconnected)
        )

        _ = try setup.configureAfterReview()

        XCTAssertEqual(integration.actions, [.readHookHashes, .registerCompanion, .finishConfiguration])
    }

    func testManagedRuntimeIntegrityFailsClosedAndRequiresEveryExecutableCopyToMatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundled = directory.appending(path: "bundled")
        let staged = directory.appending(path: "staged")
        let installed = directory.appending(path: "installed")
        let runtime = Data("current-runtime".utf8)
        for url in [bundled, staged, installed] {
            try runtime.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let digest = ManagedRuntimeIntegrity.digest(runtime)

        XCTAssertTrue(
            ManagedRuntimeIntegrity.isCurrent(
                recordedDigest: digest,
                runtimeURLs: [bundled, staged, installed]
            )
        )
        XCTAssertFalse(
            ManagedRuntimeIntegrity.isCurrent(
                recordedDigest: nil,
                runtimeURLs: [bundled, staged, installed]
            )
        )
        XCTAssertFalse(
            ManagedRuntimeIntegrity.isCurrent(
                recordedDigest: digest,
                runtimeURLs: [bundled, directory.appending(path: "missing"), installed]
            )
        )

        try Data("stale-runtime".utf8).write(to: installed)
        XCTAssertFalse(
            ManagedRuntimeIntegrity.isCurrent(
                recordedDigest: digest,
                runtimeURLs: [bundled, staged, installed]
            )
        )
        try runtime.write(to: installed)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staged.path)
        XCTAssertFalse(
            ManagedRuntimeIntegrity.isCurrent(
                recordedDigest: digest,
                runtimeURLs: [bundled, staged, installed]
            )
        )
    }

    func testConfigurationFailsClosedWhenFinalManagedRuntimeIntegrityIsStillInvalid() throws {
        let integration = RecordingSetupIntegration(
            health: SetupIntegrationHealth(
                pluginInstalled: true,
                hooksTrusted: true,
                companionRegistered: true,
                managedStatePresent: false
            ),
            persistSucceeds: false
        )
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([.desktopApp]),
            integration: integration,
            keyboard: FixedSetupKeyboard(.connected(protocolHealthy: true))
        )

        XCTAssertThrowsError(try setup.configureAfterReview()) { error in
            XCTAssertEqual(error as? GuidedSetupError, .configurationIncomplete)
        }
        XCTAssertEqual(
            integration.actions,
            [
                .stage,
                .readHookHashes,
                .resetRuntimeState,
                .registerCompanion,
                .persistConfigured,
            ]
        )
    }

    func testChangedOrUntrustedDefinitionsAreRestagedBeforeRenewedConsent() throws {
        let integration = RecordingSetupIntegration(
            health: SetupIntegrationHealth(
                pluginInstalled: true,
                hooksTrusted: false,
                companionRegistered: true,
                managedStatePresent: true
            )
        )
        let setup = GuidedSetup(
            hosts: FixedCodexHostDetector([.desktopApp]),
            integration: integration,
            keyboard: FixedSetupKeyboard(.disconnected)
        )

        _ = try setup.configureAfterReview()

        XCTAssertEqual(integration.actions, [.stage, .readHookHashes, .trust, .finishConfiguration])
    }

    func testConfiguredNeedsHealthyKeyboardBeforeItCanBeReady() throws {
        let health = SetupIntegrationHealth(
            pluginInstalled: true,
            hooksTrusted: true,
            companionRegistered: true,
            managedStatePresent: true
        )
        let configured = GuidedSetup(
            hosts: FixedCodexHostDetector([.commandLine]),
            integration: RecordingSetupIntegration(health: health),
            keyboard: FixedSetupKeyboard(.disconnected)
        )
        let ready = GuidedSetup(
            hosts: FixedCodexHostDetector([.commandLine]),
            integration: RecordingSetupIntegration(health: health),
            keyboard: FixedSetupKeyboard(.connected(protocolHealthy: true))
        )

        XCTAssertEqual(try configured.inspect().phase, .configured)
        XCTAssertEqual(try ready.inspect().phase, .ready)
    }
}

private struct FixedCodexHostDetector: CodexHostDetecting {
    let hosts: Set<CodexHost>

    init(_ hosts: Set<CodexHost>) {
        self.hosts = hosts
    }

    func detectHosts() throws -> Set<CodexHost> { hosts }
}

private struct FixedSetupKeyboard: SetupKeyboardHealthProviding {
    let health: KeyboardHealth

    init(_ health: KeyboardHealth) {
        self.health = health
    }

    func currentKeyboardHealth() -> KeyboardHealth { health }
}

private final class RecordingSetupIntegration: GuidedSetupIntegrating {
    enum Action: Equatable {
        case beginLegacyMigration
        case disableLegacyHooks
        case stopLegacyCompanion
        case verifyLegacyCompanionStopped
        case removeLegacyComponents
        case stage
        case readHookHashes
        case trust
        case resetRuntimeState
        case registerCompanion
        case persistConfigured
        case setLoginLaunch(Bool)
        case finishConfiguration
        case completeLegacyMigration
        case completeLegacyHookConsent
        case completeLegacySignalPreview
    }

    private(set) var actions: [Action] = []
    private var integrationHealth: SetupIntegrationHealth
    private let hashes: [HookEvent: String]
    private let persistSucceeds: Bool
    private var legacyMigrationStatus: LegacyMigrationStatus
    private let legacyCompanionStops: Bool
    let unrelatedPluginState = "preserved"

    init(
        health: SetupIntegrationHealth = .notConfigured,
        hashes: [HookEvent: String] = Dictionary(
            uniqueKeysWithValues: HookDefinition.reviewedRelease.map { ($0.event, $0.reviewedHash) }
        ),
        persistSucceeds: Bool = true,
        legacyMigrationStatus: LegacyMigrationStatus = .none,
        legacyCompanionStops: Bool = true
    ) {
        integrationHealth = health
        self.hashes = hashes
        self.persistSucceeds = persistSucceeds
        self.legacyMigrationStatus = legacyMigrationStatus
        self.legacyCompanionStops = legacyCompanionStops
    }

    func inspectLegacyMigration() throws -> LegacyMigrationStatus { legacyMigrationStatus }

    func beginLegacyMigration() throws {
        actions.append(.beginLegacyMigration)
        legacyMigrationStatus = .repairRequired(legacyMigrationStatus.components)
    }

    func disableLegacyHooks() throws { actions.append(.disableLegacyHooks) }

    func stopLegacyCompanion() throws { actions.append(.stopLegacyCompanion) }

    func legacyCompanionIsStopped() throws -> Bool {
        actions.append(.verifyLegacyCompanionStopped)
        return legacyCompanionStops
    }

    func removeLegacyComponents() throws { actions.append(.removeLegacyComponents) }

    func completeLegacyMigration() throws {
        actions.append(.completeLegacyMigration)
        legacyMigrationStatus = .awaitingHookConsent(legacyMigrationStatus.components)
    }

    func completeLegacyHookConsent() throws {
        actions.append(.completeLegacyHookConsent)
        legacyMigrationStatus = .awaitingSignalPreview(legacyMigrationStatus.components)
    }

    func completeLegacySignalPreview() throws {
        actions.append(.completeLegacySignalPreview)
        legacyMigrationStatus = .none
    }

    func health() throws -> SetupIntegrationHealth { integrationHealth }

    func stage(_ hooks: [HookDefinition]) throws {
        actions.append(.stage)
        integrationHealth = SetupIntegrationHealth(
            pluginInstalled: true,
            hooksTrusted: integrationHealth.hooksTrusted,
            companionRegistered: integrationHealth.companionRegistered,
            managedStatePresent: integrationHealth.managedStatePresent
        )
    }

    func installedHookHashes() throws -> [HookEvent: String] {
        actions.append(.readHookHashes)
        return hashes
    }

    func trust(_ hooks: [HookDefinition]) throws {
        actions.append(.trust)
        integrationHealth = SetupIntegrationHealth(
            pluginInstalled: integrationHealth.pluginInstalled,
            hooksTrusted: true,
            companionRegistered: integrationHealth.companionRegistered,
            managedStatePresent: integrationHealth.managedStatePresent
        )
    }

    func resetRuntimeState() throws {
        actions.append(.resetRuntimeState)
    }

    func registerCompanion() throws {
        actions.append(.registerCompanion)
        integrationHealth = SetupIntegrationHealth(
            pluginInstalled: integrationHealth.pluginInstalled,
            hooksTrusted: integrationHealth.hooksTrusted,
            companionRegistered: true,
            managedStatePresent: integrationHealth.managedStatePresent
        )
    }

    func persistConfigured() throws {
        actions.append(.persistConfigured)
        guard persistSucceeds else { return }
        integrationHealth = SetupIntegrationHealth(
            pluginInstalled: integrationHealth.pluginInstalled,
            hooksTrusted: integrationHealth.hooksTrusted,
            companionRegistered: integrationHealth.companionRegistered,
            managedStatePresent: true
        )
    }

    func setLoginLaunchEnabled(_ enabled: Bool) throws {
        actions.append(.setLoginLaunch(enabled))
    }

    func finishConfiguration() throws {
        actions.append(.finishConfiguration)
    }
}
