import Darwin
import AppKit
import Foundation
import KeyphoreCore
import ServiceManagement

struct SystemCodexHostDetector: CodexHostDetecting {
    let fileManager: FileManager
    let environment: [String: String]
    let homeDirectory: URL
    let registeredDesktopAppURL: URL?

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        registeredDesktopAppURL: URL? = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        )
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.registeredDesktopAppURL = registeredDesktopAppURL
    }

    func detectHosts() throws -> Set<CodexHost> {
        var hosts: Set<CodexHost> = []
        if desktopCodexURL != nil {
            hosts.insert(.desktopApp)
        }
        if commandLineCodexURL != nil {
            hosts.insert(.commandLine)
        }
        return hosts
    }

    var preferredCodexURL: URL? {
        CodexRuntimeCompatibility.preferredURL(
            commandLine: commandLineCodexURL,
            desktop: desktopCodexURL
        )
    }

    private var desktopCodexURL: URL? {
        let applications = [
            registeredDesktopAppURL,
            URL(fileURLWithPath: "/Applications/Codex.app"),
            homeDirectory.appending(path: "Applications/Codex.app"),
        ].compactMap { $0 }
        return applications
            .map { $0.appending(path: "Contents/Resources/codex") }
            .first(where: isExecutable)
    }

    private var commandLineCodexURL: URL? {
        let path = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let searchDirectories = path
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) } + [
                homeDirectory.appending(path: ".local/bin"),
                URL(fileURLWithPath: "/opt/homebrew/bin"),
                URL(fileURLWithPath: "/usr/local/bin"),
            ]
        return searchDirectories
            .map { $0.appending(path: "codex") }
            .first(where: isExecutable)
    }

    private func isExecutable(_ url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }
}

final class SystemGuidedSetupIntegration: GuidedSetupIntegrating {
    private static let pluginID = "keyphore@keyphore-app"
    private static let launchLabel = "com.barrywu.keyphore.companion"

    private let fileManager: FileManager
    private let codexURL: URL
    private let helperURL: URL
    private let supportDirectory: URL
    private let launchAgentsDirectory: URL
    private let launchctlURL: URL

    init?(
        detector: SystemCodexHostDetector,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl")
    ) {
        guard let codexURL = detector.preferredCodexURL else {
            return nil
        }
        self.fileManager = fileManager
        self.codexURL = codexURL
        helperURL = bundle.bundleURL.appending(path: "Contents/Helpers/keyphore")
        supportDirectory = homeDirectory.appending(path: "Library/Application Support/Keyphore")
        launchAgentsDirectory = homeDirectory.appending(path: "Library/LaunchAgents")
        self.launchctlURL = launchctlURL
    }

    func health() throws -> SetupIntegrationHealth {
        let pluginInstalled = try installedPluginIDs().contains(Self.pluginID)
        let hooks = pluginInstalled ? try hookMetadata() : []
        let actual = Dictionary(uniqueKeysWithValues: hooks.compactMap { metadata in
            metadata.event.map { ($0, metadata.currentHash) }
        })
        let hooksTrusted = actual == HookDefinition.reviewedHashes && hooks.allSatisfy {
            $0.enabled && $0.trustStatus == "trusted"
        }
        return SetupIntegrationHealth(
            pluginInstalled: pluginInstalled,
            hooksTrusted: hooksTrusted,
            companionRegistered: companionIsRegistered(),
            managedStatePresent: managedStateIsCurrent(hooks: hooks)
        )
    }

    func stage(_ hooks: [HookDefinition]) throws {
        guard hooks == HookDefinition.reviewedRelease else {
            throw GuidedSetupError.reviewedHooksChanged
        }
        try materializeMarketplace()
        if !(try marketplaceIsInstalled()) {
            _ = try runCodex(["plugin", "marketplace", "add", marketplaceRoot.path, "--json"])
        }
        _ = try runCodex(["plugin", "add", Self.pluginID, "--json"])
    }

    func installedHookHashes() throws -> [HookEvent: String] {
        try validateOwnedMetadata(hookMetadata())
    }

    func trust(_ hooks: [HookDefinition]) throws {
        let metadata = try hookMetadata()
        let hashes = try validateOwnedMetadata(metadata)
        guard hashes == HookDefinition.reviewedHashes else {
            throw GuidedSetupError.reviewedHooksChanged
        }
        try CodexAppServer(codexURL: codexURL).trustAndEnable(metadata)
        let trusted = try hookMetadata()
        guard trusted.allSatisfy({ $0.enabled && $0.trustStatus == "trusted" }) else {
            throw SystemSetupError.codexRejectedHookConsent
        }
    }

    func resetRuntimeState() throws {
        try DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL())
            .reset(lockBudget: .seconds(1))
    }

    func registerCompanion() throws {
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw SystemSetupError.runtimeMissing
        }
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try companionPlist.data(using: .utf8)?.write(to: launchAgentURL, options: .atomic)
        _ = try? run(launchctlURL, ["bootout", launchTarget])
        _ = try run(launchctlURL, ["bootstrap", launchDomain, launchAgentURL.path])
        _ = try run(launchctlURL, ["kickstart", "-k", launchTarget])
    }

    func persistConfigured() throws {
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let state: [String: Any] = [
            "version": 1,
            "plugin_id": Self.pluginID,
            "reviewed_release_digest": HookDefinition.reviewedReleaseDigest,
            "runtime_sha256": try helperDigest(),
            "reviewed_hook_hashes": Dictionary(
                uniqueKeysWithValues: HookDefinition.reviewedHashes.map {
                    ($0.key.rawValue, $0.value)
                }
            ),
        ]
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try data.write(to: stateURL, options: .atomic)
    }

    func setLoginLaunchEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
        if !enabled, fileManager.fileExists(atPath: launchAgentURL.path) {
            try fileManager.removeItem(at: launchAgentURL)
        }
    }

    func loginLaunchEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    var isQuitGateActive: Bool { quitGate.isActive }

    func activateQuitGate() throws {
        try quitGate.activate()
    }

    func disableOwnedHooks() throws {
        let metadata = try hookMetadata()
        guard metadata.count == HookDefinition.reviewedRelease.count,
              Set(metadata.compactMap(\.event)).count == HookDefinition.reviewedRelease.count
        else {
            throw SystemSetupError.unexpectedHookDefinition
        }
        try CodexAppServer(codexURL: codexURL).setEnabled(metadata, enabled: false)
        guard try hookMetadata().allSatisfy({ !$0.enabled }) else {
            throw SystemSetupError.codexRejectedHookState
        }
    }

    func stopCompanion() throws {
        _ = try? run(launchctlURL, ["bootout", launchTarget])
        guard (try? run(launchctlURL, ["print", launchTarget])) == nil else {
            throw SystemSetupError.companionStillRunning
        }
        if fileManager.fileExists(atPath: launchAgentURL.path) {
            try fileManager.removeItem(at: launchAgentURL)
        }
    }

    func clearManagedRuntimeState() throws {
        try resetRuntimeState()
        for url in [
            KeyphoreRuntimePaths.keyboardHealthURL(),
            KeyphoreRuntimePaths.signalPreviewURL(),
            KeyphoreRuntimePaths.signalOffAcknowledgementURL(),
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func requestSignalOff() throws {
        let acknowledgement = SignalOffAcknowledgementStore(
            url: KeyphoreRuntimePaths.signalOffAcknowledgementURL()
        )
        try acknowledgement.clear()
        let healthURL = KeyphoreRuntimePaths.keyboardHealthURL()
        if fileManager.fileExists(atPath: healthURL.path) {
            try fileManager.removeItem(at: healthURL)
        }
        try resetRuntimeState()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if acknowledgement.isAcknowledged {
                return
            }
            if fileManager.fileExists(atPath: healthURL.path),
               KeyboardHealthStore(url: healthURL).load() == .disconnected
            {
                return
            }
            usleep(10_000)
        }
        throw SystemSetupError.signalOffNotAcknowledged
    }

    func enableOwnedHooksIfTrusted() throws -> Bool {
        let metadata = try hookMetadata()
        guard
            (try? validateOwnedMetadata(metadata)) == HookDefinition.reviewedHashes,
            metadata.allSatisfy({ $0.trustStatus == "trusted" })
        else {
            return false
        }
        try CodexAppServer(codexURL: codexURL).setEnabled(metadata, enabled: true)
        let enabled = try hookMetadata()
        guard enabled.allSatisfy({ $0.enabled && $0.trustStatus == "trusted" }) else {
            throw SystemSetupError.codexRejectedHookState
        }
        return true
    }

    func startCompanion() throws {
        try registerCompanion()
        if !loginLaunchEnabled(), fileManager.fileExists(atPath: launchAgentURL.path) {
            try fileManager.removeItem(at: launchAgentURL)
        }
    }

    func clearQuitGate() throws {
        try quitGate.clear()
    }

    func finishConfiguration() throws {
        guard quitGate.isActive else { return }
        try clearManagedRuntimeState()
        try requestSignalOff()
        try clearQuitGate()
    }

    private var marketplaceRoot: URL { supportDirectory.appending(path: "Marketplace") }
    private var pluginRoot: URL { marketplaceRoot.appending(path: "plugin") }
    private var stateURL: URL { supportDirectory.appending(path: "setup.json") }
    private var quitGate: QuitGateStore {
        QuitGateStore(url: KeyphoreRuntimePaths.quitGateURL())
    }
    private var launchAgentURL: URL {
        launchAgentsDirectory.appending(path: "\(Self.launchLabel).plist")
    }
    private var launchDomain: String { "gui/\(geteuid())" }
    private var launchTarget: String { "\(launchDomain)/\(Self.launchLabel)" }

    private func marketplaceIsInstalled() throws -> Bool {
        let output = try runCodex(["plugin", "marketplace", "list", "--json"])
        let root = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let marketplaces = root?["marketplaces"] as? [[String: Any]] ?? []
        return marketplaces.contains { $0["name"] as? String == "keyphore-app" }
    }

    private func installedPluginIDs() throws -> Set<String> {
        let output = try runCodex(["plugin", "list", "--json"])
        let root = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let installed = root?["installed"] as? [[String: Any]] ?? []
        return Set(installed.compactMap { entry in
            guard entry["enabled"] as? Bool == true else { return nil }
            return entry["pluginId"] as? String
        })
    }

    private func hookMetadata() throws -> [CodexHookMetadata] {
        try CodexAppServer(codexURL: codexURL).hooks(in: pluginRoot)
            .filter { $0.pluginID == Self.pluginID }
    }

    private func validateOwnedMetadata(_ metadata: [CodexHookMetadata]) throws -> [HookEvent: String] {
        guard metadata.count == HookDefinition.reviewedRelease.count else {
            throw SystemSetupError.unexpectedHookDefinition
        }
        var hashes: [HookEvent: String] = [:]
        for hook in metadata {
            guard
                let event = hook.event,
                hook.handlerType == "command",
                hook.executionMode == nil || hook.executionMode == "sync",
                hook.command?.hasSuffix("/bin/keyphore\" hook") == true,
                hook.timeoutSec == 1,
                !hook.isManaged,
                hook.matcher == nil,
                hook.statusMessage == nil,
                hook.additionalContextLimit == nil,
                hook.sourcePath.hasSuffix("/hooks/hooks.json")
            else {
                throw SystemSetupError.unexpectedHookDefinition
            }
            hashes[event] = hook.currentHash
        }
        guard hashes.count == HookDefinition.reviewedRelease.count else {
            throw SystemSetupError.unexpectedHookDefinition
        }
        return hashes
    }

    private func companionIsRegistered() -> Bool {
        return (try? run(launchctlURL, ["print", launchTarget])) != nil
    }

    private func managedStateIsCurrent(hooks: [CodexHookMetadata]) -> Bool {
        guard
            let data = try? Data(contentsOf: stateURL),
            let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            state["plugin_id"] as? String == Self.pluginID,
            state["reviewed_release_digest"] as? String
                == HookDefinition.reviewedReleaseDigest,
            let recordedDigest = state["runtime_sha256"] as? String
        else {
            return false
        }
        let installedRuntimeURLs = Set(hooks.map {
            URL(fileURLWithPath: $0.sourcePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "bin/keyphore")
        })
        guard installedRuntimeURLs.count == 1, let installedRuntimeURL = installedRuntimeURLs.first
        else {
            return false
        }
        return ManagedRuntimeIntegrity.isCurrent(
            recordedDigest: recordedDigest,
            runtimeURLs: [
                helperURL,
                pluginRoot.appending(path: "bin/keyphore"),
                installedRuntimeURL,
            ],
            fileManager: fileManager
        )
    }

    private func helperDigest() throws -> String {
        ManagedRuntimeIntegrity.digest(try Data(contentsOf: helperURL))
    }

    private func materializeMarketplace() throws {
        let manifestDirectory = marketplaceRoot.appending(path: ".agents/plugins")
        let pluginManifestDirectory = pluginRoot.appending(path: ".codex-plugin")
        let hooksDirectory = pluginRoot.appending(path: "hooks")
        let binaryDirectory = pluginRoot.appending(path: "bin")
        for directory in [manifestDirectory, pluginManifestDirectory, hooksDirectory, binaryDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try marketplaceJSON.write(
            to: manifestDirectory.appending(path: "marketplace.json"),
            atomically: true,
            encoding: .utf8
        )
        try pluginJSON.write(
            to: pluginManifestDirectory.appending(path: "plugin.json"),
            atomically: true,
            encoding: .utf8
        )
        try hooksData().write(to: hooksDirectory.appending(path: "hooks.json"), options: .atomic)
        let installedHelper = binaryDirectory.appending(path: "keyphore")
        if fileManager.fileExists(atPath: installedHelper.path) {
            try fileManager.removeItem(at: installedHelper)
        }
        try fileManager.copyItem(at: helperURL, to: installedHelper)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedHelper.path)
    }

    private func runCodex(_ arguments: [String]) throws -> Data {
        try run(codexURL, arguments)
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SystemSetupError.commandFailed
        }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

    private var companionPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(Self.launchLabel)</string>
        <key>ProgramArguments</key><array><string>\(xml(helperURL.path))</string><string>companion</string></array>
        <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
        </dict></plist>
        """
    }

    private var marketplaceJSON: String {
        """
        {"name":"keyphore-app","interface":{"displayName":"Keyphore"},"plugins":[{"name":"keyphore","source":{"source":"local","path":"./plugin"},"policy":{"installation":"AVAILABLE","authentication":"ON_INSTALL"},"category":"Productivity"}]}
        """
    }

    private var pluginJSON: String {
        """
        {"name":"keyphore","version":"0.1.0","description":"Keyphore Codex lifecycle integration","author":{"name":"Barry Barry Wu"},"interface":{"displayName":"Keyphore","shortDescription":"Show Codex task status on Air65 V3","developerName":"Barry Barry Wu","category":"Productivity","capabilities":["Interactive"]}}
        """
    }

    private func hooksData() throws -> Data {
        let hooks = Dictionary(uniqueKeysWithValues: HookDefinition.reviewedRelease.map { definition in
            (
                definition.event.rawValue,
                [["hooks": [[
                    "type": "command",
                    "command": definition.command,
                    "timeout": definition.timeoutSeconds,
                ]]]]
            )
        })
        return try JSONSerialization.data(withJSONObject: [
            "description": "Record privacy-allowlisted Codex lifecycle events for Keyphore status lighting.",
            "hooks": hooks,
        ], options: [.sortedKeys])
    }

    private func xml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

@MainActor
private final class SystemKeyphoreRuntimeAdapter: KeyphoreRuntimeManaging {
    private let integration: SystemGuidedSetupIntegration

    init(integration: SystemGuidedSetupIntegration) {
        self.integration = integration
    }

    var isQuitGateActive: Bool { integration.isQuitGateActive }
    func activateQuitGate() throws { try integration.activateQuitGate() }
    func disableOwnedHooks() throws { try integration.disableOwnedHooks() }
    func stopCompanion() throws { try integration.stopCompanion() }
    func clearManagedRuntimeState() throws { try integration.clearManagedRuntimeState() }
    func requestSignalOff() throws { try integration.requestSignalOff() }
    func enableOwnedHooksIfTrusted() throws -> Bool {
        try integration.enableOwnedHooksIfTrusted()
    }
    func startCompanion() throws { try integration.startCompanion() }
    func clearQuitGate() throws { try integration.clearQuitGate() }
}

private enum SystemSetupError: Error {
    case commandFailed
    case codexRejectedHookConsent
    case codexRejectedHookState
    case companionStillRunning
    case signalOffNotAcknowledged
    case runtimeMissing
    case unexpectedHookDefinition
}

private final class CodexAppServer {
    private let codexURL: URL

    init(codexURL: URL) {
        self.codexURL = codexURL
    }

    func hooks(in root: URL) throws -> [CodexHookMetadata] {
        let result = try request(method: "hooks/list", params: ["cwds": [root.path]])
        guard
            let data = result["data"] as? [[String: Any]],
            let first = data.first,
            (first["errors"] as? [Any] ?? []).isEmpty,
            let hooks = first["hooks"]
        else {
            throw SystemSetupError.commandFailed
        }
        let encoded = try JSONSerialization.data(withJSONObject: hooks)
        return try JSONDecoder().decode([CodexHookMetadata].self, from: encoded)
    }

    func setEnabled(_ hooks: [CodexHookMetadata], enabled: Bool) throws {
        let states = Dictionary(uniqueKeysWithValues: hooks.map { hook in
            (hook.key, ["enabled": enabled] as [String: Any])
        })
        try write(states)
    }

    func trustAndEnable(_ hooks: [CodexHookMetadata]) throws {
        let states = Dictionary(uniqueKeysWithValues: hooks.map { hook in
            (hook.key, ["enabled": true, "trusted_hash": hook.currentHash] as [String: Any])
        })
        try write(states)
    }

    private func write(_ states: [String: [String: Any]]) throws {
        _ = try request(
            method: "config/batchWrite",
            params: [
                "edits": [[
                    "keyPath": "hooks.state",
                    "value": states,
                    "mergeStrategy": "upsert",
                ]],
                "reloadUserConfig": true,
            ]
        )
    }

    private func request(method: String, params: [String: Any]) throws -> [String: Any] {
        let session = try AppServerSession(codexURL: codexURL)
        return try session.request(method: method, params: params)
    }
}

private final class AppServerSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var readBuffer = Data()

    init(codexURL: URL) throws {
        process.executableURL = codexURL
        process.arguments = CodexRuntimeCompatibility.appServerArguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        try send(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "keyphore", "version": "0.1.0"],
        ])
        _ = try readResult(id: 1)
        try sendNotification(method: "initialized")
    }

    deinit {
        input.fileHandleForWriting.closeFile()
        if process.isRunning {
            process.terminate()
        }
    }

    func request(method: String, params: [String: Any]) throws -> [String: Any] {
        try send(id: 2, method: method, params: params)
        return try readResult(id: 2)
    }

    private func send(id: Int, method: String, params: [String: Any]) throws {
        try write(["id": id, "method": method, "params": params])
    }

    private func sendNotification(method: String) throws {
        try write(["method": method])
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readResult(id: Int) throws -> [String: Any] {
        while true {
            let line = try readLine(timeoutMilliseconds: 5_000)
            guard
                let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                message["id"] as? Int == id
            else {
                continue
            }
            guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
                throw SystemSetupError.commandFailed
            }
            return result
        }
    }

    private func readLine(timeoutMilliseconds: Int32) throws -> Data {
        let descriptor = output.fileHandleForReading.fileDescriptor
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.prefix(upTo: newline)
                readBuffer.removeSubrange(...newline)
                return Data(line)
            }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, timeoutMilliseconds) > 0 else {
                throw SystemSetupError.commandFailed
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count > 0 else {
                throw SystemSetupError.commandFailed
            }
            readBuffer.append(contentsOf: bytes.prefix(count))
        }
    }
}

private struct SetupKeyboardAdapter: SetupKeyboardHealthProviding {
    private let store = KeyboardHealthStore(url: KeyphoreRuntimePaths.keyboardHealthURL())

    func currentKeyboardHealth() -> KeyboardHealth { store.load() }
}

extension GuidedSetup {
    @MainActor
    static func system() -> GuidedSetup? {
        systemServices().setup
    }

    @MainActor
    static func systemServices() -> (setup: GuidedSetup, runtime: (any KeyphoreRuntimeManaging)?) {
        let detector = SystemCodexHostDetector()
        guard let integration = SystemGuidedSetupIntegration(detector: detector) else {
            return (
                GuidedSetup(
                    hosts: detector,
                    integration: MissingHostIntegration(),
                    keyboard: SetupKeyboardAdapter()
                ),
                nil
            )
        }
        return (
            GuidedSetup(hosts: detector, integration: integration, keyboard: SetupKeyboardAdapter()),
            SystemKeyphoreRuntimeAdapter(integration: integration)
        )
    }
}

private final class MissingHostIntegration: GuidedSetupIntegrating {
    func health() throws -> SetupIntegrationHealth { .notConfigured }
    func stage(_ hooks: [HookDefinition]) throws { throw GuidedSetupError.codexHostMissing }
    func installedHookHashes() throws -> [HookEvent: String] { [:] }
    func trust(_ hooks: [HookDefinition]) throws { throw GuidedSetupError.codexHostMissing }
    func resetRuntimeState() throws { throw GuidedSetupError.codexHostMissing }
    func registerCompanion() throws { throw GuidedSetupError.codexHostMissing }
    func persistConfigured() throws { throw GuidedSetupError.codexHostMissing }
    func setLoginLaunchEnabled(_ enabled: Bool) throws { throw GuidedSetupError.codexHostMissing }
}
