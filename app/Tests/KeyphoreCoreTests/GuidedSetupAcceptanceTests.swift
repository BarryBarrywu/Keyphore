import XCTest
import KeyphoreCore

@MainActor
final class GuidedSetupAcceptanceTests: XCTestCase {
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
        XCTAssertFalse(HookField.allCases.map(\.rawValue).contains("prompt"))
        XCTAssertFalse(HookField.allCases.map(\.rawValue).contains("tool_response"))
        XCTAssertFalse(HookField.allCases.map(\.rawValue).contains("transcript_path"))
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
            [.stage, .readHookHashes, .trust, .registerCompanion, .persistConfigured]
        )
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

    func testInterruptedSetupRepairsOnlyMissingOwnedComponents() throws {
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
            [.readHookHashes, .registerCompanion, .persistConfigured]
        )
        XCTAssertEqual(integration.unrelatedPluginState, "preserved")
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
        case stage
        case readHookHashes
        case trust
        case registerCompanion
        case persistConfigured
    }

    private(set) var actions: [Action] = []
    private let integrationHealth: SetupIntegrationHealth
    private let hashes: [HookEvent: String]
    let unrelatedPluginState = "preserved"

    init(
        health: SetupIntegrationHealth = .notConfigured,
        hashes: [HookEvent: String] = Dictionary(
            uniqueKeysWithValues: HookDefinition.reviewedRelease.map { ($0.event, $0.reviewedHash) }
        )
    ) {
        integrationHealth = health
        self.hashes = hashes
    }

    func health() throws -> SetupIntegrationHealth { integrationHealth }

    func stage(_ hooks: [HookDefinition]) throws {
        actions.append(.stage)
    }

    func installedHookHashes() throws -> [HookEvent: String] {
        actions.append(.readHookHashes)
        return hashes
    }

    func trust(_ hooks: [HookDefinition]) throws {
        actions.append(.trust)
    }

    func registerCompanion() throws {
        actions.append(.registerCompanion)
    }

    func persistConfigured() throws {
        actions.append(.persistConfigured)
    }
}
