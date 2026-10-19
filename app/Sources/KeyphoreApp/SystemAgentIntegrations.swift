import Darwin
import Foundation
import KeyphoreCore

struct AgentSourceSnapshot: Equatable, Sendable {
    let source: AgentSource
    let available: Bool
    let installed: Bool
    let approved: Bool
    let needsReview: Bool
}

struct AgentIntegrationReview: Sendable {
    let source: AgentSource
    let digest: String
    let events: [String]
    let files: [URL]
}

enum AgentIntegrationError: Error {
    case unavailable, reviewChanged, modifiedOwnedFile, unownedFile, invalidAsset
    case commandFailed, registrationMissing, codexUsesGuidedSetup
}

private struct NativeAgentRegistration: Codable, Equatable {
    let id: String
    let installPath: String
    var sourcePath: String? = nil
}

private struct NativeAgentRegistrationIntent: Codable {
    let source: AgentSource
    let definitionDigest: String
    let pluginPath: String
    let installed: Bool
    var installPath: String? = nil
}

/// Owns only Keyphore plugin files. Host CLIs own their registration/configuration format.
final class SystemAgentIntegrations: @unchecked Sendable {
    typealias CommandRunner = (URL, [String]) throws -> Data
    typealias AssetProvider = (AgentSource, URL) throws -> [String: Data]

    private let home: URL
    private let environment: [String: String]
    private let helperURL: URL
    private let runner: CommandRunner
    private let assets: AssetProvider
    private let prepareRuntime: (() throws -> Void)?
    private let fileManager: FileManager
    private var support: URL { KeyphoreRuntimePaths.supportDirectory(homeDirectory: home) }
    private var consentStore: AgentIntegrationConsentStore {
        AgentIntegrationConsentStore(url: KeyphoreRuntimePaths.agentIntegrationsURL(homeDirectory: home))
    }

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        helperURL: URL? = nil,
        commandRunner: CommandRunner? = nil,
        assetProvider: AssetProvider? = nil,
        prepareRuntime: (() throws -> Void)? = nil
    ) {
        home = homeDirectory
        self.environment = environment
        self.fileManager = fileManager
        self.helperURL = helperURL ?? Bundle.main.bundleURL.appending(path: "Contents/Helpers/keyphore")
        runner = commandRunner ?? { executable, arguments in
            try Self.run(executable, arguments, environment: environment, homeDirectory: homeDirectory)
        }
        assets = assetProvider ?? { source, helper in
            try AgentIntegrationAssets.files(for: source, helperURL: helper)
        }
        self.prepareRuntime = prepareRuntime
    }

    func snapshots() throws -> [AgentSourceSnapshot] {
        try sourceSnapshots(checkNativeRegistration: true)
    }

    func localSnapshots() throws -> [AgentSourceSnapshot] {
        try sourceSnapshots(checkNativeRegistration: false)
    }

    private func sourceSnapshots(checkNativeRegistration: Bool) throws -> [AgentSourceSnapshot] {
        let manifest = try consentStore.load()
        var revoked: [String: AgentSourceConsent] = [:]
        let result = AgentSource.allCases.map { source in
            if source == .codex {
                let installed = fileManager.fileExists(atPath:
                    KeyphoreRuntimePaths.configuredStateURL(homeDirectory: home).path)
                return AgentSourceSnapshot(source: source, available: executable(source) != nil,
                    installed: installed, approved: installed, needsReview: !installed)
            }
            let consent = manifest.sources[source.rawValue]
            var approved = consent.map { $0.enabled && filesMatch($0, source: source) } ?? false
            if checkNativeRegistration, approved, usesNativePlugin(source) {
                let registered = try? registeredPlugin(source, requiringEnabled: true)
                let receipt = try? registrationReceipt(source)
                approved = registered != nil && registered == receipt
            }
            if let consent, consent.enabled, !approved { revoked[source.rawValue] = consent }
            return AgentSourceSnapshot(source: source, available: executable(source) != nil,
                installed: consent != nil, approved: approved, needsReview: consent != nil && !approved)
        }
        // Native queries happen outside the lock. Revoke only the unchanged snapshot
        // so a concurrent reviewed installation cannot be overwritten by this refresh.
        if checkNativeRegistration, !revoked.isEmpty {
            try withInstallationLock {
                var current = try consentStore.load()
                var removed: [AgentSource] = []
                for (key, sampled) in revoked where current.sources[key] == sampled {
                    current.sources[key]?.enabled = false
                    if let source = AgentSource(rawValue: key) { removed.append(source) }
                }
                try consentStore.save(current)
                let store = DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL(homeDirectory: home))
                for source in removed { try store.removeProduct(source, lockBudget: .seconds(1)) }
            }
        }
        return result
    }

    func hasReadySource() throws -> Bool {
        try localSnapshots().contains { $0.source != .codex && $0.approved }
    }

    func revalidateApprovals() throws {
        _ = try snapshots()
    }

    func review(_ source: AgentSource) throws -> AgentIntegrationReview {
        guard source != .codex else { throw AgentIntegrationError.codexUsesGuidedSetup }
        guard executable(source) != nil else { throw AgentIntegrationError.unavailable }
        let files = try plannedFiles(source)
        return AgentIntegrationReview(source: source,
            digest: definitionDigest(source, files: files),
            events: AgentIntegrationAssets.events(for: source),
            files: files.keys.sorted().map { URL(fileURLWithPath: $0) })
    }

    func install(_ source: AgentSource, reviewedDigest: String) throws {
        try withInstallationLock {
            let reviewed = try review(source)
            guard reviewed.digest == reviewedDigest else { throw AgentIntegrationError.reviewChanged }
            let files = try plannedFiles(source)
            var manifest = try consentStore.load()
            let previous = manifest.sources[source.rawValue]
            if let previous {
                try assertOwnedFilesUnchanged(previous, source: source)
            }
            for path in files.keys where fileManager.fileExists(atPath: path) {
                guard manifest.sources[source.rawValue]?.assets[path] != nil else {
                    throw AgentIntegrationError.unownedFile
                }
            }
            var replacingNativePlugin = false
            if usesNativePlugin(source) {
                let existing = try registeredPlugin(source)
                if let existing {
                    try recoverRegistrationReceipt(source, registration: existing, manifest: &manifest)
                    guard let previous = manifest.sources[source.rawValue],
                          let receipt = try? registrationReceipt(source),
                          existing == receipt,
                          previous.assets[receiptURL(source).path] != nil else {
                        throw AgentIntegrationError.unownedFile
                    }
                    replacingNativePlugin = true
                }
            }
            let runtimeData = try Data(contentsOf: helperURL)
            var consent = AgentSourceConsent(enabled: false, definitionDigest: reviewed.digest,
                runtimeDigest: ManagedRuntimeIntegrity.digest(runtimeData),
                assets: files.mapValues(ManagedRuntimeIntegrity.digest))
            // Reinstall known owned plugins: some hosts keep same-version cache bytes,
            // while others reject installing an already registered local plugin.
            var pending = manifest.sources[source.rawValue] ?? consent
            pending.enabled = false
            manifest.sources[source.rawValue] = pending
            try consentStore.save(manifest)
            try DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL(homeDirectory: home))
                .removeProduct(source, lockBudget: .seconds(1))
            if replacingNativePlugin { try unregister(source) }
            let managedPrefix = support.appending(path: "integrations/\(source.rawValue)").path + "/"
            pending.assets = pending.assets.filter { $0.key.hasPrefix(managedPrefix) }
            for path in files.keys.sorted() {
                let url = URL(fileURLWithPath: path)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files[path]!.write(to: url, options: .atomic)
                pending.assets[path] = consent.assets[path]
            }
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtimeURL(source).path)
            let pluginHelper = pluginURL(source).appending(path: "bin/keyphore")
            if files[pluginHelper.path] != nil {
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pluginHelper.path)
            }
            pending.definitionDigest = consent.definitionDigest
            pending.runtimeDigest = consent.runtimeDigest
            if usesNativePlugin(source) {
                let intent = NativeAgentRegistrationIntent(source: source, definitionDigest: reviewed.digest,
                    pluginPath: pluginURL(source).path, installed: false)
                let data = try encodeMetadata(intent)
                try data.write(to: intentURL(source), options: .atomic)
                pending.assets[intentURL(source).path] = ManagedRuntimeIntegrity.digest(data)
            }
            manifest.sources[source.rawValue] = pending
            try consentStore.save(manifest)
            try register(source) { installedPath in
                // Record successful native registration before enable/list/byte verification.
                // A later failure must not lose ownership of the plugin we just installed.
                let intent = NativeAgentRegistrationIntent(source: source, definitionDigest: reviewed.digest,
                    pluginPath: pluginURL(source).path, installed: true, installPath: installedPath)
                let data = try encodeMetadata(intent)
                try data.write(to: intentURL(source), options: .atomic)
                pending.assets[intentURL(source).path] = ManagedRuntimeIntegrity.digest(data)
                consent.assets[intentURL(source).path] = ManagedRuntimeIntegrity.digest(data)
                manifest.sources[source.rawValue] = pending
                try consentStore.save(manifest)
            }
            if usesNativePlugin(source) {
                guard let registration = try registeredPlugin(source, requiringEnabled: true) else {
                    throw AgentIntegrationError.registrationMissing
                }
                if let origin = registration.sourcePath, origin != pluginURL(source).path {
                    throw AgentIntegrationError.unownedFile
                }
                let cached = URL(fileURLWithPath: registration.installPath)
                guard cached.path.hasPrefix("/"), cached.path != "/", !isSymbolicLink(cached.path) else {
                    throw AgentIntegrationError.invalidAsset
                }
                // Only the files we shipped are owned; host-generated metadata stays host-owned.
                for (relative, _) in try assets(source, runtimeURL(source)) {
                    if relative == ".claude-plugin/marketplace.json" { continue }
                    let path = cached.appending(path: relative).path
                    let expected = files[pluginURL(source).appending(path: relative).path]!
                    guard let actual = try? Data(contentsOf: URL(fileURLWithPath: path)), actual == expected else {
                        throw AgentIntegrationError.registrationMissing
                    }
                    consent.assets[path] = ManagedRuntimeIntegrity.digest(actual)
                }
                let cachedHelper = cached.appending(path: "bin/keyphore")
                guard try Data(contentsOf: cachedHelper) == runtimeData else {
                    throw AgentIntegrationError.registrationMissing
                }
                consent.assets[cachedHelper.path] = consent.runtimeDigest
                let receipt = try encodeMetadata(registration)
                try receipt.write(to: receiptURL(source), options: .atomic)
                consent.assets[receiptURL(source).path] = ManagedRuntimeIntegrity.digest(receipt)
            }
            consent.enabled = true
            manifest.sources[source.rawValue] = consent
            try consentStore.save(manifest)
            do {
                if let prepareRuntime { try prepareRuntime() }
                else {
                    let detector = SystemCodexHostDetector(environment: environment, homeDirectory: home)
                    let integration = SystemGuidedSetupIntegration(detector: detector,
                        homeDirectory: home, helperURL: helperURL)
                    try integration.prepareNativeRuntime()
                }
            } catch {
                consent.enabled = false
                manifest.sources[source.rawValue] = consent
                try consentStore.save(manifest)
                throw error
            }
        }
    }

    func remove(_ source: AgentSource) throws {
        guard source != .codex else { throw AgentIntegrationError.codexUsesGuidedSetup }
        try withInstallationLock {
            var manifest = try consentStore.load()
            guard var consent = manifest.sources[source.rawValue] else { return }
            consent.enabled = false
            manifest.sources[source.rawValue] = consent
            try consentStore.save(manifest)
            try DurableStatusStore(url: KeyphoreRuntimePaths.durableStatusURL(homeDirectory: home))
                .removeProduct(source, lockBudget: .seconds(1))
            try assertOwnedFilesUnchanged(consent, source: source)
            if usesNativePlugin(source), let registration = try registeredPlugin(source) {
                try recoverRegistrationReceipt(source, registration: registration, manifest: &manifest)
                consent = manifest.sources[source.rawValue]!
            }
            try unregister(source)
            let planned = try plannedFiles(source)
            let managedPrefix = support.appending(path: "integrations/\(source.rawValue)").path + "/"
            for path in consent.assets.keys where fileManager.fileExists(atPath: path) {
                // Native CLIs own caches and may share them across configuration scopes.
                guard planned[path] != nil || path.hasPrefix(managedPrefix) else { continue }
                try fileManager.removeItem(atPath: path)
            }
            manifest.sources.removeValue(forKey: source.rawValue)
            try consentStore.save(manifest)
        }
    }

    func removeAll() throws {
        let sources = try consentStore.load().sources.keys.compactMap(AgentSource.init(rawValue:))
        for source in sources where source != .codex { try remove(source) }
    }

    private func runtimeURL(_ source: AgentSource) -> URL {
        support.appending(path: "integrations/\(source.rawValue)/bin/keyphore")
    }

    private func pluginURL(_ source: AgentSource) -> URL {
        support.appending(path: "integrations/\(source.rawValue)/plugin")
    }

    private func receiptURL(_ source: AgentSource) -> URL {
        support.appending(path: "integrations/\(source.rawValue)/registration.json")
    }

    private func intentURL(_ source: AgentSource) -> URL {
        support.appending(path: "integrations/\(source.rawValue)/registration-intent.json")
    }

    private func recoverRegistrationReceipt(_ source: AgentSource, registration: NativeAgentRegistration,
                                           manifest: inout AgentIntegrationManifest) throws {
        guard var consent = manifest.sources[source.rawValue] else { throw AgentIntegrationError.unownedFile }
        if consent.assets[receiptURL(source).path] != nil,
           (try? registrationReceipt(source)) != nil { return }
        guard let data = try? Data(contentsOf: intentURL(source)),
              consent.assets[intentURL(source).path] == ManagedRuntimeIntegrity.digest(data),
              let intent = try? JSONDecoder().decode(NativeAgentRegistrationIntent.self, from: data),
              intent.installed, intent.source == source, intent.definitionDigest == consent.definitionDigest,
              intent.pluginPath == pluginURL(source).path else {
            throw AgentIntegrationError.unownedFile
        }
        if source == .qodercli {
            guard intent.installPath == registration.installPath else { throw AgentIntegrationError.unownedFile }
        } else {
            guard registration.sourcePath == intent.pluginPath else { throw AgentIntegrationError.unownedFile }
        }
        let cached = URL(fileURLWithPath: registration.installPath)
        let planned = try plannedFiles(source)
        let pluginPrefix = pluginURL(source).path + "/"
        for (path, expected) in planned where path.hasPrefix(pluginPrefix) {
            let relative = String(path.dropFirst(pluginPrefix.count))
            if relative == ".claude-plugin/marketplace.json" { continue }
            let installed = cached.appending(path: relative)
            if fileManager.fileExists(atPath: installed.path) {
                guard !isSymbolicLink(installed.path), try Data(contentsOf: installed) == expected else {
                    throw AgentIntegrationError.modifiedOwnedFile
                }
            }
        }
        let receipt = try encodeMetadata(registration)
        try receipt.write(to: receiptURL(source), options: .atomic)
        consent.assets[receiptURL(source).path] = ManagedRuntimeIntegrity.digest(receipt)
        manifest.sources[source.rawValue] = consent
        try consentStore.save(manifest)
    }

    private func registrationReceipt(_ source: AgentSource) throws -> NativeAgentRegistration {
        try JSONDecoder().decode(NativeAgentRegistration.self, from: Data(contentsOf: receiptURL(source)))
    }

    private func encodeMetadata<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func usesNativePlugin(_ source: AgentSource) -> Bool {
        source == .claudeCode || source == .qodercli || source == .grok
    }

    private func pluginName(_ source: AgentSource) -> String { "keyphore-" + source.rawValue }

    private func plannedFiles(_ source: AgentSource) throws -> [String: Data] {
        var planned = [runtimeURL(source).path: try Data(contentsOf: helperURL)]
        let plugin = pluginURL(source)
        if source == .claudeCode || source == .qodercli || source == .grok {
            planned[plugin.appending(path: "bin/keyphore").path] = try Data(contentsOf: helperURL)
        }
        for (relative, data) in try assets(source, runtimeURL(source)) {
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                throw AgentIntegrationError.invalidAsset
            }
            planned[plugin.appending(path: relative).path] = data
        }
        switch source {
        case .pi:
            let root = absoluteEnvironmentDirectory("PI_CODING_AGENT_DIR") ?? home.appending(path: ".pi/agent")
            guard let script = planned[plugin.appending(path: "keyphore.ts").path] else {
                throw AgentIntegrationError.invalidAsset
            }
            planned[root.appending(path: "extensions/keyphore.ts").path] = script
        case .opencode:
            let root = absoluteEnvironmentDirectory("OPENCODE_CONFIG_DIR")
                ?? (absoluteEnvironmentDirectory("XDG_CONFIG_HOME") ?? home.appending(path: ".config"))
                    .appending(path: "opencode")
            guard let script = planned[plugin.appending(path: "keyphore.js").path] else {
                throw AgentIntegrationError.invalidAsset
            }
            planned[root.appending(path: "plugins/keyphore.js").path] = script
        default: break
        }
        return planned
    }

    private func absoluteEnvironmentDirectory(_ key: String) -> URL? {
        guard let value = environment[key], value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value)
    }

    private func executable(_ source: AgentSource) -> URL? {
        let detector = SystemCodexHostDetector(fileManager: fileManager, environment: environment, homeDirectory: home)
        if source == .codex { return detector.preferredCodexURL }
        if let executable = detector.commandLineURL(named: source.executableName) { return executable }
        let nativeInstall: URL?
        switch source {
        case .opencode:
            nativeInstall = home.appending(path: ".opencode/bin/opencode")
        case .grok:
            nativeInstall = (absoluteEnvironmentDirectory("GROK_BIN_DIR") ?? home.appending(path: ".grok/bin"))
                .appending(path: "grok")
        default: nativeInstall = nil
        }
        return nativeInstall.flatMap { fileManager.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    private func register(_ source: AgentSource, didInstall: (String?) throws -> Void) throws {
        guard let command = executable(source) else { throw AgentIntegrationError.unavailable }
        let plugin = pluginURL(source)
        switch source {
        case .claudeCode:
            _ = try runner(command, ["plugin", "marketplace", "add", plugin.path])
            _ = try runner(command, ["plugin", "install", "\(pluginName(source))@keyphore-app", "--scope", "user"])
            try didInstall(nil)
        case .qodercli:
            _ = try runner(command, ["plugins", "validate", plugin.path, "--strict", "--json"])
            let response = try runner(command, ["plugins", "install", plugin.path, "--scope", "user", "--json"])
            let result = try JSONSerialization.jsonObject(with: response) as? [String: Any]
            try didInstall(result?["path"] as? String)
        case .grok:
            _ = try runner(command, ["plugin", "install", plugin.path, "--trust"])
            try didInstall(nil)
            _ = try runner(command, ["plugin", "enable", pluginName(source)])
        case .pi, .opencode: break
        case .codex: throw AgentIntegrationError.codexUsesGuidedSetup
        }
    }

    private func unregister(_ source: AgentSource) throws {
        if source == .pi || source == .opencode { return }
        guard let command = executable(source) else { throw AgentIntegrationError.unavailable }
        guard let registered = try registeredPlugin(source) else { return }
        let receipt = try registrationReceipt(source)
        guard registered == receipt else {
            throw AgentIntegrationError.modifiedOwnedFile
        }
        switch source {
        case .claudeCode:
            _ = try runner(command, ["plugin", "uninstall", receipt.id, "--scope", "user", "--keep-data", "--json"])
            _ = try runner(command, ["plugin", "marketplace", "remove", "keyphore-app"])
        case .qodercli:
            _ = try runner(command, ["plugins", "uninstall", receipt.id, "--scope", "user", "--keep-data", "--json"])
        case .grok:
            _ = try runner(command, ["plugin", "uninstall", receipt.id, "--confirm", "--keep-data"])
        default: break
        }
        guard try registeredPlugin(source) == nil else { throw AgentIntegrationError.registrationMissing }
    }

    private func registeredPlugin(_ source: AgentSource, requiringEnabled: Bool = false) throws -> NativeAgentRegistration? {
        guard let command = executable(source) else { throw AgentIntegrationError.unavailable }
        let output = try runner(command, [source == .qodercli ? "plugins" : "plugin", "list", "--json"])
        guard let rows = try JSONSerialization.jsonObject(with: output) as? [[String: Any]] else {
            throw AgentIntegrationError.registrationMissing
        }
        let matches = rows.filter { row in
            if source == .claudeCode { return row["id"] as? String == "\(pluginName(source))@keyphore-app" }
            return row["name"] as? String == pluginName(source)
                || row["id"] as? String == "\(pluginName(source))@local"
        }
        guard matches.count <= 1 else { throw AgentIntegrationError.unownedFile }
        guard let row = matches.first else { return nil }
        if source == .grok {
            guard row["status"] as? String == "installed",
                  let path = row["path"] as? String, path.hasPrefix("/"),
                  let name = row["name"] as? String else {
                throw AgentIntegrationError.registrationMissing
            }
            return NativeAgentRegistration(id: name, installPath: path, sourcePath: row["source"] as? String)
        }
        if requiringEnabled, row["enabled"] as? Bool != true {
            throw AgentIntegrationError.registrationMissing
        }
        guard let id = row["id"] as? String, let path = row["installPath"] as? String,
              path.hasPrefix("/"), (row["scope"] as? String) == "user" else {
            throw AgentIntegrationError.registrationMissing
        }
        return NativeAgentRegistration(id: id, installPath: path, sourcePath: row["readFromFolder"] as? String)
    }

    private func definitionDigest(_ source: AgentSource, files: [String: Data]) -> String {
        let canonical = files.keys.sorted().map {
            $0 + "\n" + ManagedRuntimeIntegrity.digest(files[$0]!)
        }.joined(separator: "\n")
        return ManagedRuntimeIntegrity.digest(Data((source.rawValue + "\n" + canonical).utf8))
    }

    private func filesMatch(_ consent: AgentSourceConsent, source: AgentSource) -> Bool {
        guard let bundled = try? Data(contentsOf: helperURL),
              ManagedRuntimeIntegrity.digest(bundled) == consent.runtimeDigest,
              let planned = try? plannedFiles(source),
              definitionDigest(source, files: planned) == consent.definitionDigest else { return false }
        return !consent.assets.isEmpty && consent.assets.allSatisfy { path, digest in
            guard !isSymbolicLink(path) else { return false }
            if path.hasSuffix("/bin/keyphore"), !fileManager.isExecutableFile(atPath: path) { return false }
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
            return ManagedRuntimeIntegrity.digest(bytes) == digest
        }
    }

    private func assertOwnedFilesUnchanged(_ consent: AgentSourceConsent, source: AgentSource) throws {
        let planned = try plannedFiles(source)
        let managedPrefix = support.appending(path: "integrations/\(source.rawValue)").path + "/"
        let receipt = try? registrationReceipt(source)
        for (path, digest) in consent.assets where fileManager.fileExists(atPath: path) {
            let cachePrefix = receipt.map { $0.installPath + "/" }
            guard planned[path] != nil || path.hasPrefix(managedPrefix)
                    || (cachePrefix.map { path.hasPrefix($0) } ?? false) else {
                throw AgentIntegrationError.invalidAsset
            }
            guard !isSymbolicLink(path),
                  ManagedRuntimeIntegrity.digest(try Data(contentsOf: URL(fileURLWithPath: path))) == digest
            else { throw AgentIntegrationError.modifiedOwnedFile }
        }
    }

    private func isSymbolicLink(_ path: String) -> Bool {
        (try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func withInstallationLock(_ operation: () throws -> Void) throws {
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        let descriptor = open(support.appending(path: "agent-integrations.install.lock").path,
            O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AgentIntegrationError.commandFailed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AgentIntegrationError.commandFailed }
        defer { flock(descriptor, LOCK_UN) }
        try operation()
    }

    private static func run(_ executable: URL, _ arguments: [String],
                            environment: [String: String], homeDirectory: URL) throws -> Data {
        let process = Process()
        let output = FileManager.default.temporaryDirectory.appending(path: "keyphore-plugin-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw AgentIntegrationError.commandFailed
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment.merging(["HOME": homeDirectory.path]) { _, new in new }
        process.currentDirectoryURL = homeDirectory
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let stopDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw AgentIntegrationError.commandFailed
        }
        guard process.terminationStatus == 0 else { throw AgentIntegrationError.commandFailed }
        try handle.close()
        return try Data(contentsOf: output)
    }
}
