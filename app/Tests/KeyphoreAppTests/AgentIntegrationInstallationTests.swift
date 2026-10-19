import Foundation
import XCTest
import KeyphoreCore

final class AgentIntegrationInstallationTests: XCTestCase {
    func testMinimalGUIPathFindsNativeOpenCodeAndGrokInstallations() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        for path in [".opencode/bin/opencode", ".grok/bin/grok"] {
            let executable = fixture.home.appending(path: path)
            try fixture.write("#!/bin/sh\nexit 0\n", at: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let manager = SystemAgentIntegrations(homeDirectory: fixture.home,
            environment: ["PATH": "/usr/bin:/bin"], fileManager: AgentFixtureFileManager(root: fixture.root),
            helperURL: fixture.helper, prepareRuntime: {})
        let snapshots = try manager.snapshots()
        XCTAssertEqual(snapshots.first { $0.source == .opencode }?.available, true)
        XCTAssertEqual(snapshots.first { $0.source == .grok }?.available, true)
        let override = fixture.root.appending(path: "grok-bin")
        try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.home.appending(path: ".grok/bin/grok"),
                                        to: override.appending(path: "grok"))
        let customized = SystemAgentIntegrations(homeDirectory: fixture.home,
            environment: ["PATH": "/usr/bin:/bin", "GROK_BIN_DIR": override.path],
            fileManager: AgentFixtureFileManager(root: fixture.root), helperURL: fixture.helper, prepareRuntime: {})
        XCTAssertEqual(try customized.snapshots().first { $0.source == .grok }?.available, true)
    }

    func testPiReviewInstallAndRemovePreservesOtherSourcesAndFiles() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let thirdParty = fixture.home.appending(path: ".pi/agent/extensions/other.ts")
        try fixture.write("other plugin", at: thirdParty)
        let store = DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL(homeDirectory: fixture.home))
        let otherOwner = SignalOwnerID(product: "codex", sessionID: "same", agentID: "main")
        try store.recordSignal(ownerID: otherOwner, turnID: "turn", signal: .execution,
            expiresAt: .now.adding(.seconds(60)), replacingSession: false, lockBudget: .seconds(1))
        var commands: [[String]] = []
        var preparations = 0
        let manager = fixture.manager(runner: { _, args in commands.append(args); return Data() },
            prepare: { preparations += 1 })
        let review = try manager.review(.pi)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest.path))
        try manager.install(.pi, reviewedDigest: review.digest)
        XCTAssertEqual(preparations, 1)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(try manager.hasReadySource())
        XCTAssertEqual(try store.load().owners.map(\.id), [otherOwner])
        let extensionURL = fixture.home.appending(path: ".pi/agent/extensions/keyphore.ts")
        XCTAssertEqual(try String(contentsOf: extensionURL, encoding: .utf8), "pi extension")
        try manager.remove(.pi)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extensionURL.path))
        XCTAssertEqual(try String(contentsOf: thirdParty, encoding: .utf8), "other plugin")
        XCTAssertEqual(try store.load().owners.map(\.id), [otherOwner])
        XCTAssertFalse(try manager.hasReadySource())
    }

    func testChangedReviewAndUnownedExtensionAreRejectedBeforeAnyCommand() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        var commands = 0
        let manager = fixture.manager(runner: { _, _ in commands += 1; return Data() })
        XCTAssertThrowsError(try manager.install(.pi, reviewedDigest: "stale"))
        let review = try manager.review(.pi)
        let occupied = fixture.home.appending(path: ".pi/agent/extensions/keyphore.ts")
        try fixture.write("user file", at: occupied)
        XCTAssertThrowsError(try manager.install(.pi, reviewedDigest: review.digest))
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "user file")
        XCTAssertEqual(commands, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest.path))
    }

    func testModifiedOwnedFileIsNotOverwrittenOrRemovedAndConsentIsDisabled() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager()
        let review = try manager.review(.pi)
        try manager.install(.pi, reviewedDigest: review.digest)
        let installed = fixture.home.appending(path: ".pi/agent/extensions/keyphore.ts")
        try fixture.write("user changed", at: installed)
        XCTAssertFalse(try manager.hasReadySource())
        XCTAssertThrowsError(try manager.install(.pi, reviewedDigest: review.digest))
        XCTAssertThrowsError(try manager.remove(.pi))
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "user changed")
        XCTAssertEqual(try AgentIntegrationConsentStore(url: fixture.manifest).load()
            .sources[AgentSource.pi.rawValue]?.enabled, false)
    }

    func testCommandFailureLeavesDisabledConsentAndDoesNotStartCompanion() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        var preparations = 0
        let manager = fixture.manager(runner: { _, arguments in
            if arguments.prefix(2) == ["plugin", "list"] { return Data("[]".utf8) }
            throw AgentIntegrationError.commandFailed
        },
            prepare: { preparations += 1 })
        let review = try manager.review(.grok)
        XCTAssertThrowsError(try manager.install(.grok, reviewedDigest: review.digest))
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(try AgentIntegrationConsentStore(url: fixture.manifest).load()
            .sources[AgentSource.grok.rawValue]?.enabled, false)
    }

    func testOpenCodeHonorsExplicitConfigDirectoryWithoutEditingOtherConfiguration() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let config = fixture.home.appending(path: "custom-opencode")
        let manager = fixture.manager(environment: ["OPENCODE_CONFIG_DIR": config.path])
        let review = try manager.review(.opencode)
        try manager.install(.opencode, reviewedDigest: review.digest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.appending(path: "plugins/keyphore.js").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appending(path: ".config/opencode/config.json").path))
    }

    func testReopenRevokesOnlyModifiedSourceAndPreservesOtherSourceOwners() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager()
        for source in [AgentSource.pi, .opencode] {
            try manager.install(source, reviewedDigest: manager.review(source).digest)
        }
        let store = DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL(homeDirectory: fixture.home))
        for source in [AgentSource.pi, .opencode] {
            try store.recordSignal(ownerID: SignalOwnerID(product: source.rawValue, sessionID: "same", agentID: "main"),
                turnID: "turn", signal: .execution, expiresAt: .now.adding(.seconds(60)),
                replacingSession: false, lockBudget: .seconds(1))
        }
        try fixture.write("changed", at: fixture.home.appending(path: ".pi/agent/extensions/keyphore.ts"))
        try manager.revalidateApprovals()
        let manifest = try AgentIntegrationConsentStore(url: fixture.manifest).load()
        XCTAssertEqual(manifest.sources["pi"]?.enabled, false)
        XCTAssertEqual(manifest.sources["opencode"]?.enabled, true)
        XCTAssertEqual(try store.load().owners.map { $0.id.product }, ["opencode"])
        XCTAssertTrue(try manager.hasReadySource())
    }

    func testNativeInstallVerifiesCachedBytesAndRemovesOnlyExactOwnedPluginID() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let cache = fixture.root.appending(path: "cache/keyphore")
        var registered = false
        var commands: [[String]] = []
        let manager = fixture.manager(runner: { _, args in
            commands.append(args)
            if args.prefix(2) == ["plugins", "install"] {
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: args[2]), to: cache)
                registered = true
                return try JSONSerialization.data(withJSONObject: ["path": cache.path])
            }
            if args.prefix(2) == ["plugins", "uninstall"] {
                registered = false
                if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
            }
            if args.prefix(2) == ["plugins", "list"] {
                var rows: [[String: Any]] = [["id": "other@local", "name": "other", "scope": "user"]]
                if registered {
                    rows.append(["id": "keyphore-qodercli@local", "name": "keyphore-qodercli", "scope": "user",
                                 "enabled": true, "installPath": cache.path])
                }
                return try JSONSerialization.data(withJSONObject: rows)
            }
            return Data()
        })
        try manager.install(.qodercli, reviewedDigest: manager.review(.qodercli).digest)
        let manifest = try AgentIntegrationConsentStore(url: fixture.manifest).load()
        XCTAssertNotNil(manifest.sources["qodercli"]?.assets[cache.appending(path: "bin/keyphore").path])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cache.appending(path: "bin/keyphore").path))
        try fixture.write("#!/bin/sh\n# new same-version helper\nexit 0\n", at: fixture.helper)
        let updatedReview = try manager.review(.qodercli)
        try manager.install(.qodercli, reviewedDigest: updatedReview.digest)
        XCTAssertEqual(try Data(contentsOf: cache.appending(path: "bin/keyphore")),
                       try Data(contentsOf: fixture.helper))
        XCTAssertEqual(commands.filter { $0.prefix(2) == ["plugins", "uninstall"] }.count, 1)
        try manager.remove(.qodercli)
        XCTAssertTrue(commands.contains(["plugins", "uninstall", "keyphore-qodercli@local", "--scope", "user", "--keep-data", "--json"]))
        XCTAssertFalse(commands.contains { $0.contains("other@local") })
    }

    func testExistingUnownedNativePluginIsNeverReplaced() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        var commands: [[String]] = []
        let manager = fixture.manager(runner: { _, args in
            commands.append(args)
            return try JSONSerialization.data(withJSONObject: [[
                "id": "keyphore-qodercli@local", "name": "keyphore-qodercli", "scope": "user", "enabled": true,
                "installPath": fixture.root.appending(path: "user-keyphore").path,
            ]])
        })
        XCTAssertThrowsError(try manager.install(.qodercli, reviewedDigest: manager.review(.qodercli).digest))
        XCTAssertEqual(commands, [["plugins", "list", "--json"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest.path))
    }

    func testFailedNativeReplacementStaysDisabledUntilReviewedRetry() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let cache = fixture.root.appending(path: "cache/grok")
        var registered = false
        var failInstall = false
        let manager = fixture.manager(runner: { _, args in
            if args.prefix(2) == ["plugin", "list"] {
                return try JSONSerialization.data(withJSONObject: registered ? [[
                    "status": "installed", "name": "keyphore-grok", "path": cache.path,
                ]] : [])
            }
            if args.prefix(2) == ["plugin", "install"] {
                if failInstall { throw AgentIntegrationError.commandFailed }
                if registered { throw AgentIntegrationError.commandFailed }
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: args[2]), to: cache)
                registered = true
            }
            if args.prefix(2) == ["plugin", "uninstall"] {
                registered = false
                try FileManager.default.removeItem(at: cache)
            }
            return Data()
        })
        try manager.install(.pi, reviewedDigest: manager.review(.pi).digest)
        try manager.install(.grok, reviewedDigest: manager.review(.grok).digest)
        let status = DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL(homeDirectory: fixture.home))
        for source in [AgentSource.pi, .grok] {
            try status.recordSignal(ownerID: SignalOwnerID(product: source.rawValue, sessionID: "session", agentID: "main"),
                turnID: "turn", signal: .execution, expiresAt: .now.adding(.seconds(60)),
                replacingSession: false, lockBudget: .seconds(1))
        }
        failInstall = true
        XCTAssertThrowsError(try manager.install(.grok, reviewedDigest: manager.review(.grok).digest))
        let consentStore = AgentIntegrationConsentStore(url: fixture.manifest)
        XCTAssertEqual(try consentStore.load().sources["grok"]?.enabled, false)
        XCTAssertEqual(try consentStore.load().sources["pi"]?.enabled, true)
        XCTAssertEqual(try status.load().owners.map { $0.id.product }, ["pi"])
        XCTAssertFalse(registered)
        failInstall = false
        try manager.install(.grok, reviewedDigest: manager.review(.grok).digest)
        XCTAssertEqual(try consentStore.load().sources["grok"]?.enabled, true)
        XCTAssertTrue(registered)
    }

    func testPartialNativeRegistrationCanBeRetriedOrRemovedWithoutAdoptingForeignPlugins() throws {
        for failure in ["enable", "list", "missing-cache"] {
            for removeInsteadOfRetry in [false, true] {
                let fixture = try AgentInstallFixture()
                defer { fixture.cleanUp() }
                let cache = fixture.root.appending(path: "cache/grok")
                var registered = false
                var shouldFail = true
                var origin = ""
                let manager = fixture.manager(runner: { _, args in
                    if args.prefix(2) == ["plugin", "list"] {
                        if registered, failure == "list", shouldFail {
                            shouldFail = false
                            throw AgentIntegrationError.commandFailed
                        }
                        return try JSONSerialization.data(withJSONObject: registered ? [[
                            "status": "installed", "name": "keyphore-grok", "path": cache.path, "source": origin,
                        ]] : [])
                    }
                    if args.prefix(2) == ["plugin", "install"] {
                        origin = args[2]
                        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: URL(fileURLWithPath: origin), to: cache)
                        registered = true
                        if failure == "missing-cache", shouldFail {
                            shouldFail = false
                            try FileManager.default.removeItem(at: cache.appending(path: "bin/keyphore"))
                        }
                    }
                    if args.prefix(2) == ["plugin", "enable"], failure == "enable", shouldFail {
                        shouldFail = false
                        throw AgentIntegrationError.commandFailed
                    }
                    if args.prefix(2) == ["plugin", "uninstall"] {
                        XCTAssertEqual(args[2], "keyphore-grok")
                        registered = false
                        try FileManager.default.removeItem(at: cache)
                    }
                    return Data()
                })
                XCTAssertThrowsError(try manager.install(.grok, reviewedDigest: manager.review(.grok).digest), failure)
                XCTAssertTrue(registered)
                XCTAssertEqual(try AgentIntegrationConsentStore(url: fixture.manifest).load().sources["grok"]?.enabled, false)
                if removeInsteadOfRetry {
                    try manager.remove(.grok)
                    XCTAssertFalse(registered)
                    XCTAssertNil(try AgentIntegrationConsentStore(url: fixture.manifest).load().sources["grok"])
                } else {
                    try manager.install(.grok, reviewedDigest: manager.review(.grok).digest)
                    XCTAssertTrue(try manager.hasReadySource())
                }
            }
        }
    }

    func testRefreshRevokesExternallyDisabledNativePluginWithoutBlockingOtherSources() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let cache = fixture.root.appending(path: "cache/qoder")
        var registered = false
        var enabled = true
        var commandCount = 0
        let manager = fixture.manager(runner: { _, args in
            commandCount += 1
            if args.prefix(2) == ["plugins", "install"] {
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: args[2]), to: cache)
                registered = true
                return try JSONSerialization.data(withJSONObject: ["path": cache.path])
            }
            if args.prefix(2) == ["plugins", "list"] {
                return try JSONSerialization.data(withJSONObject: registered ? [[
                    "id": "keyphore-qodercli@local", "name": "keyphore-qodercli", "scope": "user",
                    "enabled": enabled, "installPath": cache.path,
                ]] : [])
            }
            return Data()
        })
        for source in [AgentSource.pi, .qodercli] {
            try manager.install(source, reviewedDigest: manager.review(source).digest)
        }
        let store = DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL(homeDirectory: fixture.home))
        for source in [AgentSource.pi, .qodercli] {
            try store.recordSignal(ownerID: SignalOwnerID(product: source.rawValue, sessionID: "session", agentID: "main"),
                turnID: "turn", signal: .execution, expiresAt: .now.adding(.seconds(60)),
                replacingSession: false, lockBudget: .seconds(1))
        }
        enabled = false
        let beforeLocalSnapshot = commandCount
        XCTAssertEqual(try manager.localSnapshots().first { $0.source == .qodercli }?.approved, true)
        XCTAssertEqual(commandCount, beforeLocalSnapshot)
        let refreshed = try manager.snapshots()
        XCTAssertEqual(refreshed.first { $0.source == .qodercli }?.approved, false)
        XCTAssertEqual(refreshed.first { $0.source == .qodercli }?.needsReview, true)
        XCTAssertEqual(refreshed.first { $0.source == .pi }?.approved, true)
        XCTAssertEqual(try store.load().owners.map { $0.id.product }, ["pi"])
        let beforeFastHealth = commandCount
        XCTAssertTrue(try manager.hasReadySource())
        XCTAssertEqual(commandCount, beforeFastHealth)
    }

    func testPendingReceiptRejectsForeignOriginAndMismatchedQoderInstallPath() throws {
        for source in [AgentSource.grok, .qodercli] {
            let fixture = try AgentInstallFixture()
            defer { fixture.cleanUp() }
            let cache = fixture.root.appending(path: "cache/expected")
            var reportedCache = cache
            var origin = ""
            var registered = false
            var failVerification = true
            var uninstallCount = 0
            let manager = fixture.manager(runner: { _, args in
                if args[1] == "list" {
                    if registered, failVerification {
                        failVerification = false
                        throw AgentIntegrationError.commandFailed
                    }
                    guard registered else { return Data("[]".utf8) }
                    if source == .grok {
                        return try JSONSerialization.data(withJSONObject: [[
                            "status": "installed", "name": "keyphore-grok", "path": reportedCache.path,
                            "source": origin,
                        ]])
                    }
                    return try JSONSerialization.data(withJSONObject: [[
                        "id": "keyphore-qodercli@local", "name": "keyphore-qodercli", "scope": "user",
                        "enabled": true, "installPath": reportedCache.path,
                    ]])
                }
                if args[1] == "install" {
                    origin = args[2]
                    try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: origin), to: cache)
                    registered = true
                    if source == .qodercli { return try JSONSerialization.data(withJSONObject: ["path": cache.path]) }
                }
                if args[1] == "uninstall" { uninstallCount += 1 }
                return Data()
            })
            XCTAssertThrowsError(try manager.install(source, reviewedDigest: manager.review(source).digest))
            if source == .grok {
                origin = fixture.root.appending(path: "foreign-plugin").path
            } else {
                reportedCache = fixture.root.appending(path: "foreign-cache")
                try FileManager.default.copyItem(at: cache, to: reportedCache)
            }
            XCTAssertThrowsError(try manager.install(source, reviewedDigest: manager.review(source).digest))
            XCTAssertThrowsError(try manager.remove(source))
            XCTAssertEqual(uninstallCount, 0)
            XCTAssertEqual(try AgentIntegrationConsentStore(url: fixture.manifest).load()
                .sources[source.rawValue]?.enabled, false)
        }
    }

    func testStaleRefreshCannotRevokeNewApprovalAfterSameByteReinstall() throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let cache = fixture.root.appending(path: "cache/qoder")
        var registered = false
        var repairDuringNextList = false
        var installCount = 0
        var manager: SystemAgentIntegrations!
        manager = fixture.manager(runner: { _, args in
            if args[1] == "install" {
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: args[2]), to: cache)
                registered = true
                installCount += 1
                return try JSONSerialization.data(withJSONObject: ["path": cache.path])
            }
            if args[1] == "uninstall" {
                registered = false
                try FileManager.default.removeItem(at: cache)
            }
            if args[1] == "list" {
                guard registered else { return Data("[]".utf8) }
                var row: [String: Any] = ["id": "keyphore-qodercli@local", "name": "keyphore-qodercli",
                    "scope": "user", "enabled": true, "installPath": cache.path]
                if repairDuringNextList {
                    repairDuringNextList = false
                    try manager.install(.qodercli, reviewedDigest: manager.review(.qodercli).digest)
                    // An old query completes after the reviewed repair with its earlier disabled state.
                    row["enabled"] = false
                }
                return try JSONSerialization.data(withJSONObject: [row])
            }
            return Data()
        })
        try manager.install(.qodercli, reviewedDigest: manager.review(.qodercli).digest)
        let store = AgentIntegrationConsentStore(url: fixture.manifest)
        let before = try XCTUnwrap(store.load().sources["qodercli"])
        repairDuringNextList = true
        _ = try manager.snapshots()
        let after = try XCTUnwrap(store.load().sources["qodercli"])
        XCTAssertEqual(installCount, 2)
        XCTAssertEqual(before.definitionDigest, after.definitionDigest)
        XCTAssertEqual(before.runtimeDigest, after.runtimeDigest)
        XCTAssertEqual(before.assets, after.assets)
        XCTAssertNotEqual(before.approvalID, after.approvalID)
        XCTAssertTrue(after.enabled)
        XCTAssertTrue(try manager.hasReadySource())
        var disabled = after
        disabled.enabled = false
        XCTAssertEqual(disabled.approvalID, after.approvalID)
        var missingIdentity = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(after)) as? [String: Any])
        missingIdentity.removeValue(forKey: "approvalID")
        XCTAssertThrowsError(try JSONDecoder().decode(AgentSourceConsent.self,
            from: JSONSerialization.data(withJSONObject: missingIdentity)))
    }
}

private final class AgentInstallFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "keyphore-agents-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var bin: URL { root.appending(path: "bin") }
    var helper: URL { root.appending(path: "keyphore") }
    var manifest: URL { KeyphoreRuntimePaths.agentIntegrationsURL(homeDirectory: home) }

    init() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try write("#!/bin/sh\nexit 0\n", at: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        for source in AgentSource.allCases {
            let executable = bin.appending(path: source.executableName)
            try write("#!/bin/sh\nexit 0\n", at: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
    }

    func manager(environment: [String: String] = [:],
                 runner: @escaping SystemAgentIntegrations.CommandRunner = { _, _ in Data() },
                 prepare: @escaping () throws -> Void = {}) -> SystemAgentIntegrations {
        SystemAgentIntegrations(homeDirectory: home,
            environment: environment.merging(["PATH": bin.path]) { _, value in value },
            fileManager: AgentFixtureFileManager(root: root),
            helperURL: helper, commandRunner: runner,
            assetProvider: { source, _ in
                switch source {
                case .pi: ["keyphore.ts": Data("pi extension".utf8)]
                case .opencode: ["keyphore.js": Data("opencode plugin".utf8)]
                default: ["plugin.json": Data("{\"name\":\"keyphore-\(source.rawValue)\"}".utf8)]
                }
            }, prepareRuntime: prepare)
    }

    func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private final class AgentFixtureFileManager: FileManager, @unchecked Sendable {
    private let rootPath: String
    init(root: URL) { rootPath = root.path + "/"; super.init() }
    override func isExecutableFile(atPath path: String) -> Bool {
        path.hasPrefix(rootPath) && super.isExecutableFile(atPath: path)
    }
}
