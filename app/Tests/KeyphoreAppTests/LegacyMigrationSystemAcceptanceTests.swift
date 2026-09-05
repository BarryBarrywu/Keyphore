import XCTest
import KeyphoreCore

@MainActor
final class LegacyMigrationSystemAcceptanceTests: XCTestCase {
    func testHealthyDiagnosticFieldsMatchTheRustContractAndExcludePrivateContent() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.prepareCurrentInstallation()
        try Data().write(to: fixture.currentRunning)
        let metadata: [[String: Any]] = HookDefinition.reviewedRelease.map { hook in
            ["key": hook.event.rawValue, "eventName": hook.event.rawValue.prefix(1).lowercased() + hook.event.rawValue.dropFirst(),
             "handlerType": "command", "executionMode": "sync", "command": "\"\(fixture.cachedHelper.path)\" hook", "timeoutSec": 1,
             "sourcePath": fixture.cachedPlugin.appending(path: "hooks/hooks.json").path,
             "pluginId": "keyphore@keyphore-app", "enabled": true, "isManaged": false,
             "currentHash": hook.reviewedHash, "trustStatus": "trusted"]
        }
        let response = fixture.root.appending(path: "hook-response.json")
        var responseData = try JSONSerialization.data(withJSONObject:
            ["id": 2, "result": ["data": [["cwd": "fixture", "hooks": metadata, "warnings": [], "errors": []]]]])
        responseData.append(0x0a)
        try responseData.write(to: response)
        let codex = fixture.bin.appending(path: "codex")
        let script = try String(contentsOf: codex, encoding: .utf8).replacingOccurrences(
            of: "read request\n", with: "read request\ncat '\(response.path)'\nexit 0\n")
        try script.write(to: codex, atomically: false, encoding: .utf8)
        let detector = SystemCodexHostDetector(environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home, registeredDesktopAppURL: nil)
        let integration = try XCTUnwrap(SystemGuidedSetupIntegration(detector: detector,
            homeDirectory: fixture.home, launchctlURL: fixture.launchctl,
            processListURL: fixture.processList, helperURL: fixture.helper))
        try integration.stage(HookDefinition.reviewedRelease)
        try integration.registerCompanion()
        try integration.persistConfigured()
        let store = DurableStatusStore(url: fixture.support.appending(path: "status.json"))
        try ProductionHookHandler(store: store).handle(Data(
            #"{"hook_event_name":"UserPromptSubmit","session_id":"diagnostic","turn_id":"turn-1","prompt":"PRIVATE_PROMPT_24","tool_response":"PRIVATE_RESPONSE_24","cwd":"/Users/PRIVATE_USER_24/PRIVATE_PATH_24"}"#.utf8))
        let keyboard = KeyboardHealthStore(url: fixture.support.appending(path: "keyboard-health.json"))
        try keyboard.save(.connected(protocolHealthy: true))
        let setup = GuidedSetup(hosts: detector, integration: integration,
            keyboard: ParityKeyboardHealth(store: keyboard))
        let report = DiagnosticReport(snapshot: setup.diagnosticSnapshot(
            appVersion: "0.1.0 (1)", macOSVersion: "macOS 15.6.1"), language: .english)
        let fields = Dictionary(uniqueKeysWithValues: report.fields.map { ($0.id, $0.value) })
        let observed = [
            "hooks_trusted": fields[.hook] == "Trusted",
            "companion_running": fields[.companion] == "Running",
            "keyboard_connected": fields[.keyboard] == "Connected",
            "protocol_healthy": fields[.protocolReadback] == "Healthy",
            "private_content_absent": !report.fields.contains { $0.value.contains("PRIVATE_") || $0.value.contains(fixture.root.path) },
        ]
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/fixtures/swift-parity.json")
        let specification = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        let expected = try XCTUnwrap((specification["contracts"] as? [String: [String: Bool]])?["healthy-diagnostics"])
        XCTAssertEqual(observed, expected)
        if let directory = ProcessInfo.processInfo.environment["KEYPHORE_PARITY_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: observed, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appending(path: "swift-healthy-diagnostics.json"))
            let output = URL(fileURLWithPath: directory)
            try JSONEncoder().encode(report).write(to: output.appending(path: "swift-diagnostic-preview.json"))
            try DiagnosticReportExporter().export(report, to: output.appending(path: "swift-diagnostic-report.zip"))
        }
    }

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
        let currentService = fixture.currentService
        let signalOffAcknowledgement = fixture.signalOffAcknowledgement
        DispatchQueue.global().async {
            while FileManager.default.fileExists(atPath: currentService.path) {
                try? Data().write(to: signalOffAcknowledgement)
                Thread.sleep(forTimeInterval: 0.02)
            }
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
        let otherState = try String(contentsOf: fixture.otherPluginState, encoding: .utf8)
        let observed = [
            "owned_plugin_present": plugins.contains("keyphore@keyphore-app"),
            "other_plugin_preserved": plugins.contains("other@product")
                && otherState == "preserved",
            "owned_hooks_disabled": FileManager.default.fileExists(atPath: fixture.hooksDisabled.path),
        ]
        let contractURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/fixtures/swift-parity.json")
        let contracts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as? [String: Any])
        let expected = try XCTUnwrap((contracts["contracts"] as? [String: [String: Bool]])?["managed-removal"])
        XCTAssertEqual(observed, expected)
        if let directory = ProcessInfo.processInfo.environment["KEYPHORE_PARITY_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: observed, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appending(path: "swift-managed-removal.json"))
        }
    }

    func testManagedRemovalPreservesTableExamplesInsideMultilineValues() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.prepareCurrentInstallation()
        try FileManager.default.removeItem(at: fixture.currentService)
        try FileManager.default.removeItem(at: fixture.currentLaunchAgent)
        let preserved = [
            "instructions = \"\"\"",
            "[marketplaces.keyphore-app]",
            "source = \"example\"",
            "\"\"\"",
            "examples = [",
            "[\"nested array\"],",
            "'''",
            "[plugins.\"keyphore@keyphore-app\"]",
            "'''",
            "]",
            "model = \"preserve-me\"",
            "",
        ].joined(separator: "\r\n")
        let owned = "[ 'marketplaces' . 'keyphore-app' ]\r\nsource = \"managed\"\r\n"
            + "description = '''\r\n[unrelated]\r\n# still owned content\r\n'''\r\n"
            + "[ \"plugins\" . 'keyphore@keyphore-app' ]\r\nenabled = true\r\n"
        let other = "[plugins.'other]product'] # unrelated\r\nenabled = true\r\n"
        try (preserved + owned + other).write(to: fixture.codexConfiguration,
            atomically: true, encoding: .utf8)
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.root.appending(path: "missing-bin").path],
            homeDirectory: fixture.home, registeredDesktopAppURL: nil, desktopAppURLs: [])
        let loginLaunch = RemovalLoginLaunchState()
        let integration = SystemGuidedSetupIntegration(detector: detector,
            homeDirectory: fixture.home, launchctlURL: fixture.launchctl,
            processListURL: fixture.processList,
            loginLaunchDisabler: { loginLaunch.isEnabled = false },
            loginLaunchIsEnabled: { loginLaunch.isEnabled })

        XCTAssertEqual(try ManagedRemoval(integration: integration).removeAfterConfirmation().status, .completed)
        XCTAssertEqual(try String(contentsOf: fixture.codexConfiguration, encoding: .utf8), preserved + other)
        XCTAssertTrue(try integration.verifyManagedRemoval())
    }

    func testInterruptedRemovalCompletesWithoutReinstallingACodexHost() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.prepareCurrentInstallation()
        try FileManager.default.removeItem(at: fixture.currentService)
        try FileManager.default.removeItem(at: fixture.currentLaunchAgent)
        try Data().write(to: fixture.support.appending(path: "quit-gate"))
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.root.appending(path: "missing-bin").path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil,
            desktopAppURLs: []
        )
        let loginLaunch = RemovalLoginLaunchState()
        let integration = SystemGuidedSetupIntegration(
            detector: detector,
            homeDirectory: fixture.home,
            launchctlURL: fixture.launchctl,
            processListURL: fixture.processList,
            loginLaunchDisabler: { loginLaunch.isEnabled = false },
            loginLaunchIsEnabled: { loginLaunch.isEnabled }
        )

        let removal = ManagedRemoval(integration: integration)
        XCTAssertEqual(try removal.inspect().status, .repairRequired)
        XCTAssertEqual(try removal.removeAfterConfirmation().status, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cachedHelper.path))
        let codexConfiguration = try String(contentsOf: fixture.codexConfiguration)
        XCTAssertFalse(codexConfiguration.contains("keyphore"))
        XCTAssertTrue(codexConfiguration.contains("other@product"))
    }

    func testManagedRemovalRepairsAPartialHookSetAfterDisablingTheHooksThatRemain() throws {
        let fixture = try LegacyMigrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.prepareCurrentInstallation()
        try FileManager.default.removeItem(at: fixture.fullCurrentHooks)
        let detector = SystemCodexHostDetector(
            environment: ["PATH": fixture.bin.path],
            homeDirectory: fixture.home,
            registeredDesktopAppURL: nil
        )
        let loginLaunch = RemovalLoginLaunchState()
        let integration = SystemGuidedSetupIntegration(
            detector: detector,
            homeDirectory: fixture.home,
            launchctlURL: fixture.launchctl,
            processListURL: fixture.processList,
            helperURL: fixture.helper,
            loginLaunchDisabler: { loginLaunch.isEnabled = false },
            loginLaunchIsEnabled: { loginLaunch.isEnabled }
        )
        let currentService = fixture.currentService
        let signalOffAcknowledgement = fixture.signalOffAcknowledgement
        DispatchQueue.global().async {
            while FileManager.default.fileExists(atPath: currentService.path) {
                try? Data().write(to: signalOffAcknowledgement)
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        XCTAssertEqual(
            try ManagedRemoval(integration: integration).removeAfterConfirmation().status,
            .completed
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.hooksDisabled.path))
        XCTAssertFalse(try String(contentsOf: fixture.pluginState).contains("keyphore@keyphore-app"))
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
    let codexConfiguration: URL
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
    let fullCurrentHooks: URL

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
        cachedPlugin = home.appending(path: ".codex/plugins/cache/keyphore-app/keyphore")
        cachedHelper = cachedPlugin.appending(path: "bin/keyphore")
        commandLog = root.appending(path: "commands.log")
        otherPluginState = root.appending(path: "other-plugin-state")
        pluginState = root.appending(path: "plugins.txt")
        codexConfiguration = home.appending(path: ".codex/config.toml")
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
        fullCurrentHooks = root.appending(path: "full-current-hooks")
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
            codexConfiguration.deletingLastPathComponent(),
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
              /bin/mkdir -p '\(cachedHelper.deletingLastPathComponent().path)'
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
                if [ -e '\(fullCurrentHooks.path)' ]; then
                  printf '%s\\n' '{"id":2,"result":{"data":[{"cwd":"fixture","hooks":[{"key":"permission","eventName":"permissionRequest","handlerType":"command","executionMode":"sync","matcher":null,"command":"current","timeoutSec":1,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"\(cachedPlugin.appending(path: "hooks/hooks.json").path)","pluginId":"keyphore@keyphore-app","enabled":'"$enabled"',"isManaged":false,"currentHash":"sha256:current","trustStatus":"trusted"},{"key":"post","eventName":"postToolUse","handlerType":"command","executionMode":"sync","matcher":null,"command":"current","timeoutSec":1,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"\(cachedPlugin.appending(path: "hooks/hooks.json").path)","pluginId":"keyphore@keyphore-app","enabled":'"$enabled"',"isManaged":false,"currentHash":"sha256:current","trustStatus":"trusted"},{"key":"session-end","eventName":"sessionEnd","handlerType":"command","executionMode":"sync","matcher":null,"command":"current","timeoutSec":1,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"\(cachedPlugin.appending(path: "hooks/hooks.json").path)","pluginId":"keyphore@keyphore-app","enabled":'"$enabled"',"isManaged":false,"currentHash":"sha256:current","trustStatus":"trusted"},{"key":"session-start","eventName":"sessionStart","handlerType":"command","executionMode":"sync","matcher":null,"command":"current","timeoutSec":1,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"\(cachedPlugin.appending(path: "hooks/hooks.json").path)","pluginId":"keyphore@keyphore-app","enabled":'"$enabled"',"isManaged":false,"currentHash":"sha256:current","trustStatus":"trusted"},{"key":"stop","eventName":"stop","handlerType":"command","executionMode":"sync","matcher":null,"command":"current","timeoutSec":1,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"\(cachedPlugin.appending(path: "hooks/hooks.json").path)","pluginId":"keyphore@keyphore-app","enabled":'"$enabled"',"isManaged":false,"currentHash":"sha256:current","trustStatus":"trusted"},{"key":"subagent-start","eventName":"subagentStart","handlerType":"command","executionMode":"sync","matcher":null,"command":"current","timeoutSec":1,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"\(cachedPlugin.appending(path: "hooks/hooks.json").path)","pluginId":"keyphore@keyphore-app","enabled":'"$enabled"',"isManaged":false,"currentHash":"sha256:current","trustStatus":"trusted"},{"key":"subagent-stop","eventName":"subagentStop","handlerType":"command","executionMode":"sync","matcher":null,"command":"current","timeoutSec":1,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"\(cachedPlugin.appending(path: "hooks/hooks.json").path)","pluginId":"keyphore@keyphore-app","enabled":'"$enabled"',"isManaged":false,"currentHash":"sha256:current","trustStatus":"trusted"},{"key":"prompt","eventName":"userPromptSubmit","handlerType":"command","executionMode":"sync","matcher":null,"command":"current","timeoutSec":1,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"\(cachedPlugin.appending(path: "hooks/hooks.json").path)","pluginId":"keyphore@keyphore-app","enabled":'"$enabled"',"isManaged":false,"currentHash":"sha256:current","trustStatus":"trusted"}],"warnings":[],"errors":[]}]}}'
                else
                  printf '%s\\n' '{"id":2,"result":{"data":[{"cwd":"fixture","hooks":[{"key":"current","eventName":"sessionStart","handlerType":"command","executionMode":"sync","matcher":null,"command":"current","timeoutSec":1,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"\(cachedPlugin.appending(path: "hooks/hooks.json").path)","pluginId":"keyphore@keyphore-app","enabled":'"$enabled"',"isManaged":false,"currentHash":"sha256:current","trustStatus":"trusted"}],"warnings":[],"errors":[]}]}}'
                fi
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
        try """
          [marketplaces.keyphore-app] # managed marketplace
        source_type = "local"
        source = "managed"

        # Preserve this user comment.

        [plugins."keyphore@keyphore-app"]
        enabled = true

          [plugins.'other]product'] # unrelated plugin
        enabled = true
        label = "other@product"
        """.write(to: codexConfiguration, atomically: true, encoding: .utf8)
        try Data().write(to: currentService)
        try Data().write(to: currentLaunchAgent)
        try Data().write(to: fullCurrentHooks)
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

private struct ParityKeyboardHealth: SetupKeyboardHealthProviding {
    let store: KeyboardHealthStore
    func currentKeyboardHealth() -> KeyboardHealth { store.load() }
    func currentDiagnosticKeyboardHealth() -> KeyboardHealth { store.loadDiagnosticHealth() }
}
