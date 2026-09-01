import XCTest
import KeyphoreCore

@MainActor
final class LegacyMigrationSystemAcceptanceTests: XCTestCase {
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

private struct LegacyMigrationFixture {
    let root: URL
    let home: URL
    let bin: URL
    let launchctl: URL
    let processList: URL
    let helper: URL
    let commandLog: URL
    let otherPluginState: URL
    let legacyState: URL
    let pluginState: URL
    let legacyService: URL
    let currentService: URL
    let overlapEvidence: URL
    let orphanProcess: URL
    let staleRemoval: URL

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory.appending(path: "keyphore-migration-\(UUID().uuidString)")
        home = root.appending(path: "home")
        bin = root.appending(path: "bin")
        launchctl = bin.appending(path: "launchctl")
        processList = bin.appending(path: "ps")
        helper = root.appending(path: "current-keyphore")
        commandLog = root.appending(path: "commands.log")
        otherPluginState = root.appending(path: "other-plugin-state")
        pluginState = root.appending(path: "plugins.txt")
        legacyService = root.appending(path: "legacy-service")
        currentService = root.appending(path: "current-service")
        overlapEvidence = root.appending(path: "overlap")
        orphanProcess = root.appending(path: "orphan-process")
        staleRemoval = root.appending(path: "stale-removal")
        let support = home.appending(path: "Library/Application Support/Keyphore")
        legacyState = support.appending(path: "lifecycle.json")
        let launchAgents = home.appending(path: "Library/LaunchAgents")
        let legacyPlugin = root.appending(path: "legacy-plugin")
        for directory in [bin, support, launchAgents, legacyPlugin.appending(path: "hooks")] {
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
            if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
              if /usr/bin/grep -Fxq 'keyphore@keyphore' '\(pluginState.path)'; then
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
              exit 0
            fi
            if [ "$1" = "app-server" ]; then
              read initialize
              printf '%s\\n' '{"id":1,"result":{"userAgent":"test"}}'
              read initialized
              read request
              if /usr/bin/grep -Fxq 'keyphore@keyphore' '\(pluginState.path)'; then
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
              [ -n "$marker" ] && [ -e "$marker" ]
              exit $?
            fi
            if [ "$command" = "bootout" ]; then
              [ -n "$marker" ] && /bin/rm -f "$marker"
              exit 0
            fi
            if [ "$command" = "bootstrap" ]; then
              [ -e '\(legacyService.path)' ] && /usr/bin/touch '\(overlapEvidence.path)'
              /usr/bin/touch '\(currentService.path)'
              exit 0
            fi
            if [ "$command" = "kickstart" ]; then exit 0; fi
            exit 1
            """
        )
        try Self.writeExecutable(
            to: processList,
            contents: """
            #!/bin/sh
            if [ -e '\(orphanProcess.path)' ]; then
              printf '%s\\n' '/legacy/bin/keyphore companion'
            fi
            exit 0
            """
        )
    }

    private static func writeExecutable(to url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
