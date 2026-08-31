import Darwin
import Foundation
import KeyphoreCore

struct SystemCodexHostDetector: CodexHostDetecting {
    let fileManager: FileManager
    let environment: [String: String]
    let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
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
        desktopCodexURL ?? commandLineCodexURL
    }

    private var desktopCodexURL: URL? {
        let applications = [
            URL(fileURLWithPath: "/Applications/Codex.app"),
            homeDirectory.appending(path: "Applications/Codex.app"),
        ]
        return applications
            .map { $0.appending(path: "Contents/Resources/codex") }
            .first(where: isExecutable)
    }

    private var commandLineCodexURL: URL? {
        let path = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return path
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "codex") }
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
        let expected = Dictionary(
            uniqueKeysWithValues: HookDefinition.reviewedRelease.map { ($0.event, $0.reviewedHash) }
        )
        let actual = Dictionary(uniqueKeysWithValues: hooks.compactMap { metadata in
            metadata.event.map { ($0, metadata.currentHash) }
        })
        let hooksTrusted = actual == expected && hooks.allSatisfy {
            $0.enabled && $0.trustStatus == "trusted"
        }
        return SetupIntegrationHealth(
            pluginInstalled: pluginInstalled,
            hooksTrusted: hooksTrusted,
            companionRegistered: companionIsRegistered(),
            managedStatePresent: fileManager.fileExists(atPath: stateURL.path)
        )
    }

    func stage(_ hooks: [HookDefinition]) throws {
        try materializeMarketplace()
        if !(try marketplaceIsInstalled()) {
            _ = try runCodex(["plugin", "marketplace", "add", marketplaceRoot.path, "--json"])
        }
        if !(try installedPluginIDs().contains(Self.pluginID)) {
            _ = try runCodex(["plugin", "add", Self.pluginID, "--json"])
        }
    }

    func installedHookHashes() throws -> [HookEvent: String] {
        try validateOwnedMetadata(hookMetadata())
    }

    func trust(_ hooks: [HookDefinition]) throws {
        let metadata = try hookMetadata()
        let hashes = try validateOwnedMetadata(metadata)
        let expected = Dictionary(uniqueKeysWithValues: hooks.map { ($0.event, $0.reviewedHash) })
        guard hashes == expected else {
            throw GuidedSetupError.reviewedHooksChanged
        }
        try CodexAppServer(codexURL: codexURL).configure(metadata, enabled: true)
        let trusted = try hookMetadata()
        guard trusted.allSatisfy({ $0.enabled && $0.trustStatus == "trusted" }) else {
            throw SystemSetupError.codexRejectedHookConsent
        }
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
            "reviewed_hook_hashes": Dictionary(
                uniqueKeysWithValues: HookDefinition.reviewedRelease.map {
                    ($0.event.rawValue, $0.reviewedHash)
                }
            ),
        ]
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try data.write(to: stateURL, options: .atomic)
    }

    private var marketplaceRoot: URL { supportDirectory.appending(path: "Marketplace") }
    private var pluginRoot: URL { marketplaceRoot.appending(path: "plugin") }
    private var stateURL: URL { supportDirectory.appending(path: "setup.json") }
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
        guard fileManager.fileExists(atPath: launchAgentURL.path) else { return false }
        return (try? run(launchctlURL, ["print", launchTarget])) != nil
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
        try hooksJSON.write(
            to: hooksDirectory.appending(path: "hooks.json"),
            atomically: true,
            encoding: .utf8
        )
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

    private var hooksJSON: String {
        let definitions = HookEvent.allCases.map { event in
            "\"\(event.rawValue)\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\\\"${PLUGIN_ROOT}/bin/keyphore\\\" hook\",\"timeout\":1}]}]"
        }.joined(separator: ",")
        return "{\"description\":\"Record privacy-allowlisted Codex lifecycle events for Keyphore status lighting.\",\"hooks\":{\(definitions)}}"
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

private enum SystemSetupError: Error {
    case commandFailed
    case codexRejectedHookConsent
    case runtimeMissing
    case unexpectedHookDefinition
}

private struct CodexHookMetadata: Decodable {
    let key: String
    let eventName: String
    let handlerType: String
    let executionMode: String?
    let matcher: String?
    let command: String?
    let timeoutSec: UInt64
    let statusMessage: String?
    let additionalContextLimit: UInt64?
    let sourcePath: String
    let pluginID: String?
    let enabled: Bool
    let isManaged: Bool
    let currentHash: String
    let trustStatus: String

    var event: HookEvent? {
        HookEvent.allCases.first {
            $0.rawValue.prefix(1).lowercased() + $0.rawValue.dropFirst() == eventName
        }
    }
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

    func configure(_ hooks: [CodexHookMetadata], enabled: Bool) throws {
        let states = Dictionary(uniqueKeysWithValues: hooks.map { hook in
            (hook.key, ["enabled": enabled, "trusted_hash": hook.currentHash] as [String: Any])
        })
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
        process.arguments = ["app-server", "--stdio"]
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
    func currentKeyboardHealth() -> KeyboardHealth { .disconnected }
}

extension GuidedSetup {
    static func system() -> GuidedSetup? {
        let detector = SystemCodexHostDetector()
        guard let integration = SystemGuidedSetupIntegration(detector: detector) else {
            return GuidedSetup(
                hosts: detector,
                integration: MissingHostIntegration(),
                keyboard: SetupKeyboardAdapter()
            )
        }
        return GuidedSetup(hosts: detector, integration: integration, keyboard: SetupKeyboardAdapter())
    }
}

private final class MissingHostIntegration: GuidedSetupIntegrating {
    func health() throws -> SetupIntegrationHealth { .notConfigured }
    func stage(_ hooks: [HookDefinition]) throws { throw GuidedSetupError.codexHostMissing }
    func installedHookHashes() throws -> [HookEvent: String] { [:] }
    func trust(_ hooks: [HookDefinition]) throws { throw GuidedSetupError.codexHostMissing }
    func registerCompanion() throws { throw GuidedSetupError.codexHostMissing }
    func persistConfigured() throws { throw GuidedSetupError.codexHostMissing }
}
