import XCTest
import KeyphoreCore

@MainActor
final class LegacyMigrationSystemAcceptanceTests: XCTestCase {
    func testMissingCodexHostDoesNotGuessCompanionStopped() {
        let setup = GuidedSetup(
            hosts: MissingHostDetector(),
            integration: MissingHostIntegration(),
            keyboard: MissingHostKeyboardHealth()
        )

        let snapshot = setup.diagnosticSnapshot(
            appVersion: "0.1.0 (1)",
            macOSVersion: "macOS 15.6.1"
        )

        XCTAssertEqual(snapshot.companion, .unavailable)
    }

    func testCompanionDiagnosticsRequireARunningLaunchdJob() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList,
                helperURL: fixture.helper
            )
        )
        try Data().write(to: fixture.currentService)

        XCTAssertFalse(try integration.companionIsRunningForDiagnostics())

        try integration.registerCompanion()

        XCTAssertTrue(try integration.companionIsRunningForDiagnostics())

        try Data().write(to: fixture.launchctlFailure)

        XCTAssertThrowsError(try integration.companionIsRunningForDiagnostics())
    }

    func testCompanionRegistrationSucceedsWhenBootstrapAlreadyStartedTheJob() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data().write(to: fixture.kickstartFailure)
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList,
                helperURL: fixture.helper
            )
        )

        try integration.registerCompanion()

        XCTAssertTrue(try integration.companionIsRunningForDiagnostics())
    }

    func testRegisteredCompanionIsAssociatedWithTheKeyphoreApp() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList,
                helperURL: fixture.helper
            )
        )

        try integration.registerCompanion()

        let launchAgent = fixture.home.appending(
            path: "Library/LaunchAgents/com.barrywu.keyphore.companion.plist"
        )
        let propertyList = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: launchAgent),
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(
            propertyList["AssociatedBundleIdentifiers"] as? [String],
            ["com.barrywu.keyphore"]
        )
    }

    func testRegisteredCompanionLaunchesTheBundledCompanionApp() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                bundle: fixture.appBundle,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList
            )
        )

        try integration.registerCompanion()

        let launchAgent = fixture.home.appending(
            path: "Library/LaunchAgents/com.barrywu.keyphore.companion.plist"
        )
        let propertyList = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: launchAgent),
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(
            propertyList["ProgramArguments"] as? [String],
            [fixture.companionExecutable.path, "companion"]
        )
    }

    func testOldBareCompanionRegistrationIsNotCurrent() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data().write(to: fixture.currentService)
        let launchAgent = fixture.home.appending(
            path: "Library/LaunchAgents/com.barrywu.keyphore.companion.plist"
        )
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "com.barrywu.keyphore.companion",
                "ProgramArguments": [fixture.helper.path, "companion"],
            ],
            format: .xml,
            options: 0
        ).write(to: launchAgent)
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList,
                helperURL: fixture.helper,
                companionExecutableURL: fixture.companionExecutable
            )
        )

        XCTAssertFalse(try integration.health().companionRegistered)
    }

    func testConfigurationClearsQuitGateWhenSignalOffCannotBeAcknowledged() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList,
                helperURL: fixture.helper
            )
        )

        try integration.activateQuitGate()

        XCTAssertNoThrow(try integration.finishConfiguration())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.home.appending(
                    path: "Library/Application Support/Keyphore/quit-gate"
                ).path
            )
        )
    }

    func testOtherPluginIsNotReportedAsKeyphoreOwned() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.legacyState)
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList
            )
        )

        let health = try integration.health()

        XCTAssertFalse(health.pluginInstalled)
        XCTAssertFalse(health.hooksTrusted)
        XCTAssertFalse(health.companionRegistered)
        XCTAssertFalse(health.managedStatePresent)
        XCTAssertEqual(try String(contentsOf: fixture.otherPluginState), "preserved")
    }

    func testStagingAnInstalledPluginRefreshesItsCodexCache() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.legacyState)
        try "keyphore@keyphore-app\nother@product\n".write(
            to: fixture.pluginState,
            atomically: true,
            encoding: .utf8
        )
        try "stale-runtime".write(
            to: fixture.cachedHelper,
            atomically: true,
            encoding: .utf8
        )
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList,
                helperURL: fixture.helper
            )
        )

        try integration.stage(HookDefinition.reviewedRelease)

        let commands = try String(contentsOf: fixture.commandLog)
        XCTAssertTrue(commands.contains("plugin remove keyphore@keyphore-app"))
        XCTAssertTrue(commands.contains("plugin add keyphore@keyphore-app"))
        XCTAssertEqual(
            try Data(contentsOf: fixture.cachedHelper),
            try Data(contentsOf: fixture.helper)
        )
    }

    func testStagingRefreshesStaleHookDefinitionsWhenTheRuntimeAlreadyMatches() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.legacyState)
        try "keyphore@keyphore-app\nother@product\n".write(
            to: fixture.pluginState,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.copyItem(at: fixture.helper, to: fixture.cachedHelper)
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList,
                helperURL: fixture.helper
            )
        )

        try integration.stage(HookDefinition.reviewedRelease)

        let commands = try String(contentsOf: fixture.commandLog)
        XCTAssertTrue(commands.contains("plugin remove keyphore@keyphore-app"))
        XCTAssertTrue(commands.contains("plugin add keyphore@keyphore-app"))
    }

    func testManagedRemovalDeletesOnlyCurrentKeyphoreOwnershipAndCanNoLongerInvokeCachedHook() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.prepareCurrentInstallation()
        let unrelatedUserFile = fixture.home.appending(path: "Documents/preserved.txt")
        try FileManager.default.createDirectory(
            at: unrelatedUserFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "preserved".write(to: unrelatedUserFile, atomically: true, encoding: .utf8)
        let loginLaunch = RemovalLoginLaunchState()
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList,
                helperURL: fixture.helper,
                loginLaunchDisabler: { loginLaunch.isEnabled = false },
                loginLaunchIsEnabled: { loginLaunch.isEnabled }
            )
        )
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            try? Data().write(to: fixture.signalOffAcknowledgement)
        }

        let snapshot = try ManagedRemoval(integration: integration).removeAfterConfirmation()

        XCTAssertEqual(snapshot.status, .completed)
        XCTAssertFalse(loginLaunch.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentService.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentLaunchAgent.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cachedHelper.path))
        XCTAssertEqual(try String(contentsOf: unrelatedUserFile), "preserved")
        XCTAssertEqual(try String(contentsOf: fixture.otherPluginState), "preserved")
        let plugins = try String(contentsOf: fixture.pluginState)
        XCTAssertFalse(plugins.contains("keyphore@keyphore-app"))
        XCTAssertTrue(plugins.contains("other@product"))
    }

    func testInspectionDetectsKnownLegacyOwnershipWithoutChangingEitherPlugin() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList
            )
        )

        let status = try integration.inspectLegacyMigration()

        XCTAssertEqual(status, .reviewRequired(Set(LegacyComponent.allCases)))
        XCTAssertEqual(try String(contentsOf: fixture.otherPluginState), "preserved")
        let commands = (try? String(contentsOf: fixture.commandLog)) ?? ""
        XCTAssertFalse(commands.contains("bootout"))
        XCTAssertFalse(commands.contains("plugin remove"))
        XCTAssertFalse(commands.contains("config/batchWrite"))
    }

    func testInspectionStillFindsPartialLegacyInstallWithoutLifecycleState() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.legacyState)
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList
            )
        )

        XCTAssertEqual(
            try integration.inspectLegacyMigration(),
            .reviewRequired([.plugin, .hooks, .companionRegistration])
        )
    }

    func testSystemHandoffRemovesOnlyLegacyOwnershipBeforeCurrentCompanionStarts() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList,
                helperURL: fixture.helper
            )
        )

        try integration.stopLegacyCompanion()
        XCTAssertTrue(try integration.legacyCompanionIsStopped())
        try integration.removeLegacyComponents()
        try integration.registerCompanion()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.overlapEvidence.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyService.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.currentService.path))
        XCTAssertEqual(try String(contentsOf: fixture.otherPluginState), "preserved")
        let plugins = try String(contentsOf: fixture.pluginState)
        XCTAssertFalse(plugins.contains("keyphore@keyphore"))
        XCTAssertTrue(plugins.contains("other@product"))
        XCTAssertTrue(plugins.contains("keyphore@third-party"))
    }

    func testOrphanedCompanionProcessBlocksTheCurrentCompanion() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data().write(to: fixture.orphanProcess)
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList,
                helperURL: fixture.helper
            )
        )

        XCTAssertThrowsError(try integration.stopLegacyCompanion())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentService.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.overlapEvidence.path))
    }

    func testOrphanedBundledCompanionProcessBlocksASecondCompanion() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data().write(to: fixture.bundledOrphanProcess)
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList,
                helperURL: fixture.helper,
                companionExecutableURL: fixture.companionExecutable
            )
        )

        XCTAssertThrowsError(try integration.stopLegacyCompanion())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentService.path))
    }

    func testRemovalFailsClosedWhenCodexClaimsSuccessWithoutRemovingLegacyPlugin() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data().write(to: fixture.staleRemoval)
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList
            )
        )

        XCTAssertThrowsError(try integration.removeLegacyComponents())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacyState.path))
        XCTAssertTrue(try String(contentsOf: fixture.pluginState).contains("keyphore@keyphore"))
    }

    func testRepairCanRemoveCorruptLegacyStateAfterLegacyOwnersAreGone() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("corrupt".utf8).write(to: fixture.legacyState)
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let integration = try XCTUnwrap(
            SystemGuidedSetupIntegration(
                detector: detector,
                homeDirectory: fixture.home,
                launchctlURL: fixture.launchctl,
                processListURL: fixture.processList
            )
        )

        try integration.stopLegacyCompanion()
        try integration.removeLegacyComponents()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyState.path))
        XCTAssertFalse(try String(contentsOf: fixture.pluginState).contains("keyphore@keyphore"))
    }
}

private struct MissingHostDetector: CodexHostDetecting {
    func detectHosts() -> Set<CodexHost> { [] }
}

private struct MissingHostKeyboardHealth: SetupKeyboardHealthProviding {
    func currentKeyboardHealth() -> KeyboardHealth { .unavailable }
}

private struct LegacyMigrationFixture {
    let root: URL
    let appBundleURL: URL
    let home: URL
    let support: URL
    let bin: URL
    let launchctl: URL
    let processList: URL
    let helper: URL
    let companionExecutable: URL
    let cachedPlugin: URL
    let cachedHelper: URL
    let commandLog: URL
    let otherPluginState: URL
    let legacyState: URL
    let pluginState: URL
    let legacyService: URL
    let currentService: URL
    let currentLaunchAgent: URL
    let currentRunning: URL
    let overlapEvidence: URL
    let orphanProcess: URL
    let bundledOrphanProcess: URL
    let staleRemoval: URL
    let launchctlFailure: URL
    let kickstartFailure: URL
    let signalOffAcknowledgement: URL
    let hooksDisabled: URL

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory.appending(path: "keyphore-migration-\(UUID().uuidString)")
        appBundleURL = root.appending(path: "Keyphore.app")
        home = root.appending(path: "home")
        bin = root.appending(path: "bin")
        launchctl = bin.appending(path: "launchctl")
        processList = bin.appending(path: "ps")
        helper = appBundleURL.appending(path: "Contents/Helpers/keyphore")
        companionExecutable = appBundleURL.appending(
            path: "Contents/Library/LoginItems/Keyphore Companion.app/Contents/MacOS/Keyphore Companion"
        )
        cachedPlugin = root.appending(path: "codex-cache/keyphore")
        cachedHelper = cachedPlugin.appending(path: "bin/keyphore")
        commandLog = root.appending(path: "commands.log")
        otherPluginState = root.appending(path: "other-plugin-state")
        pluginState = root.appending(path: "plugins.txt")
        legacyService = root.appending(path: "legacy-service")
        currentService = root.appending(path: "current-service")
        currentRunning = root.appending(path: "current-running")
        overlapEvidence = root.appending(path: "overlap")
        orphanProcess = root.appending(path: "orphan-process")
        bundledOrphanProcess = root.appending(path: "bundled-orphan-process")
        staleRemoval = root.appending(path: "stale-removal")
        launchctlFailure = root.appending(path: "launchctl-failure")
        kickstartFailure = root.appending(path: "kickstart-failure")
        support = home.appending(path: "Library/Application Support/Keyphore")
        legacyState = support.appending(path: "lifecycle.json")
        let launchAgents = home.appending(path: "Library/LaunchAgents")
        currentLaunchAgent = launchAgents.appending(path: "com.barrywu.keyphore.companion.plist")
        signalOffAcknowledgement = support.appending(path: "signal-off-ack")
        hooksDisabled = root.appending(path: "hooks-disabled")
        let legacyPlugin = root.appending(path: "legacy-plugin")
        for directory in [
            bin,
            support,
            launchAgents,
            helper.deletingLastPathComponent(),
            companionExecutable.deletingLastPathComponent(),
            legacyPlugin.appending(path: "hooks"),
            cachedPlugin.appending(path: "hooks"),
            cachedPlugin.appending(path: "bin"),
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "preserved".write(to: otherPluginState, atomically: true, encoding: .utf8)
        try "keyphore@keyphore\nother@product\nkeyphore@third-party\n".write(
            to: pluginState,
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: legacyService)
        try Self.writeExecutable(to: helper, contents: "#!/bin/sh\nexit 0\n")
        try Self.writeExecutable(to: companionExecutable, contents: "#!/bin/sh\nexit 0\n")
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "Keyphore",
                "CFBundleIdentifier": "com.barrywu.keyphore.fixture.\(UUID().uuidString)",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        ).write(to: appBundleURL.appending(path: "Contents/Info.plist"))
        let companionInfoURL = companionExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Info.plist")
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "Keyphore Companion",
                "CFBundleIdentifier": "com.barrywu.keyphore.companion",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        ).write(to: companionInfoURL)
        let lifecycle = try JSONSerialization.data(withJSONObject: [
            "plugin_id": "keyphore@keyphore",
            "plugin_root": legacyPlugin.path,
        ])
        try lifecycle.write(to: legacyState)
        try Data().write(
            to: launchAgents.appending(path: "com.barrybarrywu.keyphore.plist")
        )

        try Self.writeExecutable(
            to: bin.appending(path: "codex"),
            contents: """
            #!/bin/sh
            printf 'codex %s\\n' "$*" >> '\(commandLog.path)'
            if [ "$1" = "plugin" ] && [ "$2" = "marketplace" ] && [ "$3" = "list" ]; then
              printf '%s\\n' '{"marketplaces":[]}'
              exit 0
            fi
            if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
              if /usr/bin/grep -Fxq 'keyphore@keyphore-app' '\(pluginState.path)'; then
                printf '%s\\n' '{"installed":[{"pluginId":"keyphore@keyphore-app","enabled":true},{"pluginId":"other@product","enabled":true}]}'
              elif /usr/bin/grep -Fxq 'keyphore@keyphore' '\(pluginState.path)'; then
                printf '%s\\n' '{"installed":[{"pluginId":"keyphore@keyphore","enabled":true},{"pluginId":"other@product","enabled":true},{"pluginId":"keyphore@third-party","enabled":true}]}'
              else
                printf '%s\\n' '{"installed":[{"pluginId":"other@product","enabled":true},{"pluginId":"keyphore@third-party","enabled":true}]}'
              fi
              exit 0
            fi
            if [ "$1" = "plugin" ] && [ "$2" = "remove" ]; then
              [ -e '\(staleRemoval.path)' ] && exit 0
              /usr/bin/grep -Fvx "$3" '\(pluginState.path)' > '\(pluginState.path).tmp'
              /bin/mv '\(pluginState.path).tmp' '\(pluginState.path)'
              if [ "$3" = "keyphore@keyphore-app" ]; then
                /bin/rm -rf '\(cachedPlugin.path)'
              fi
              exit 0
            fi
            if [ "$1" = "plugin" ] && [ "$2" = "add" ]; then
              /usr/bin/grep -Fxq "$3" '\(pluginState.path)' || printf '%s\\n' "$3" >> '\(pluginState.path)'
              /bin/cp '\(support.appending(path: "Marketplace/plugin/bin/keyphore").path)' '\(cachedHelper.path)'
              exit 0
            fi
            if [ "$1" = "app-server" ]; then
              read initialize
              printf '%s\\n' '{"id":1,"result":{"userAgent":"test"}}'
              read initialized
              read request
              if printf '%s' "$request" | /usr/bin/grep -q 'config/batchWrite'; then
                /usr/bin/touch '\(hooksDisabled.path)'
                printf '%s\\n' '{"id":2,"result":{}}'
                exit 0
              fi
              if /usr/bin/grep -Fxq 'keyphore@keyphore-app' '\(pluginState.path)'; then
                if [ -e '\(hooksDisabled.path)' ]; then enabled=false; else enabled=true; fi
                printf '%s\\n' '{"id":2,"result":{"data":[{"cwd":"fixture","hooks":[{"key":"current","eventName":"sessionStart","handlerType":"command","executionMode":"sync","matcher":null,"command":"current","timeoutSec":1,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"\(cachedPlugin.appending(path: "hooks/hooks.json").path)","pluginId":"keyphore@keyphore-app","enabled":'"$enabled"',"isManaged":false,"currentHash":"sha256:current","trustStatus":"trusted"}],"warnings":[],"errors":[]}]}}'
              elif /usr/bin/grep -Fxq 'keyphore@keyphore' '\(pluginState.path)'; then
                printf '%s\\n' '{"id":2,"result":{"data":[{"cwd":"fixture","hooks":[{"key":"legacy","eventName":"sessionStart","handlerType":"command","executionMode":"sync","matcher":null,"command":"legacy","timeoutSec":1,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"\(legacyPlugin.path)/hooks/hooks.json","pluginId":"keyphore@keyphore","enabled":true,"isManaged":false,"currentHash":"sha256:legacy","trustStatus":"trusted"}],"warnings":[],"errors":[]}]}}'
              else
                printf '%s\\n' '{"id":2,"result":{"data":[{"cwd":"fixture","hooks":[],"warnings":[],"errors":[]}]}}'
              fi
              exit 0
            fi
            exit 0
            """
        )
        try Self.writeExecutable(
            to: launchctl,
            contents: """
            #!/bin/sh
            printf 'launchctl %s\\n' "$*" >> '\(commandLog.path)'
            command="$1"
            target="$2"
            case "$target" in
              *com.barrybarrywu.keyphore) marker='\(legacyService.path)' ;;
              *com.barrywu.keyphore.companion) marker='\(currentService.path)' ;;
              *) marker='' ;;
            esac
            if [ "$command" = "print" ]; then
              if [ -e '\(launchctlFailure.path)' ]; then
                printf '%s\n' 'Permission denied' >&2
                exit 1
              fi
              if [ -n "$marker" ] && [ -e "$marker" ]; then
                if [ "$marker" = "\(currentService.path)" ] && [ -e '\(currentRunning.path)' ]; then
                  printf '%s\n' 'state = running'
                else
                  printf '%s\n' 'state = stopped'
                fi
                exit 0
              fi
              printf '%s\n' 'Could not find service' >&2
              exit 113
            fi
            if [ "$command" = "bootout" ]; then
              [ -n "$marker" ] && /bin/rm -f "$marker"
              if [ "$marker" = "\(currentService.path)" ]; then /bin/rm -f '\(currentRunning.path)'; fi
              exit $?
            fi
            if [ "$command" = "bootstrap" ]; then
              [ -e '\(legacyService.path)' ] && /usr/bin/touch '\(overlapEvidence.path)'
              /usr/bin/touch '\(currentService.path)'
              /usr/bin/touch '\(currentRunning.path)'
              exit 0
            fi
            if [ "$command" = "kickstart" ]; then
              [ -e '\(kickstartFailure.path)' ] && exit 1
              exit 0
            fi
            exit 1
            """
        )
        try Self.writeExecutable(
            to: processList,
            contents: """
            #!/bin/sh
            /usr/bin/awk 'BEGIN { for (i = 0; i < 10000; i++) print "/usr/bin/safe-process" }'
            if [ -e '\(orphanProcess.path)' ]; then
              printf '%s\\n' '/legacy/bin/keyphore companion'
            fi
            if [ -e '\(bundledOrphanProcess.path)' ]; then
              printf '%s\\n' '/Applications/Keyphore.app/Contents/Library/LoginItems/Keyphore Companion.app/Contents/MacOS/Keyphore Companion companion'
            fi
            exit 0
            """
        )
    }

    var appBundle: Bundle { Bundle(url: appBundleURL)! }

    func prepareCurrentInstallation() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: legacyState.path) {
            try fileManager.removeItem(at: legacyState)
        }
        try "keyphore@keyphore-app\nother@product\n".write(
            to: pluginState,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.copyItem(at: helper, to: cachedHelper)
        try Data().write(to: currentService)
        try Data().write(to: currentLaunchAgent)
        for name in [
            "setup.json",
            "profile.json",
            "keyboard-health.json",
            "signal-preview.json",
            "hardware-health.json",
        ] {
            try Data("managed".utf8).write(to: support.appending(path: name))
        }
        try DurableStatusStore(url: support.appending(path: "status.json"))
            .reset(lockBudget: .seconds(1))
    }

    private static func writeExecutable(to url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private final class RemovalLoginLaunchState: @unchecked Sendable {
    var isEnabled = true
}
