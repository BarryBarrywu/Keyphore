import Foundation

public enum CompanionDiagnosticHealth: Equatable, Sendable {
    case running
    case stopped
    case unavailable
}

public struct DiagnosticSnapshot: Equatable, Sendable {
    public let appVersion: String
    public let macOSVersion: String
    public let codexHosts: Set<CodexHost>?
    public let integration: SetupIntegrationHealth?
    public let companion: CompanionDiagnosticHealth
    public let keyboard: KeyboardHealth

    public var collectionFailed: Bool {
        codexHosts == nil || integration == nil || companion == .unavailable
    }

    public init(
        appVersion: String,
        macOSVersion: String,
        codexHosts: Set<CodexHost>?,
        integration: SetupIntegrationHealth?,
        companion: CompanionDiagnosticHealth? = nil,
        keyboard: KeyboardHealth
    ) {
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.codexHosts = codexHosts
        self.integration = integration
        self.companion = companion ?? integration.map {
            $0.companionRegistered ? .running : .stopped
        } ?? .unavailable
        self.keyboard = keyboard
    }
}

public struct DiagnosticField: Codable, Equatable, Identifiable, Sendable {
    public enum ID: String, CaseIterable, Codable, Sendable {
        case appVersion = "app_version"
        case macOS = "macos"
        case codexHost = "codex_host"
        case hook
        case companion
        case keyboard
        case protocolReadback = "protocol"
        case errorHealth = "error_health"
    }

    public let id: ID
    public let label: String
    public let value: String
    public let action: String?

    public init(id: ID, label: String, value: String, action: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.action = action
    }
}

public struct DiagnosticReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let language: AppLanguage
    public let fields: [DiagnosticField]
    public let privacyNotice: String

    public init(snapshot: DiagnosticSnapshot, language: AppLanguage) {
        schemaVersion = 1
        self.language = language
        privacyNotice = AppCopy.value(.diagnosticPrivacyNotice, language: language)

        let hook: Diagnosis
        if let integration = snapshot.integration, !integration.pluginInstalled {
            hook = Diagnosis(field: Self.field(
                .hook,
                value: .diagnosticNotInstalled,
                action: .diagnosticActionConfigure,
                language: language
            ), issue: .diagnosticIssueHookMissing)
        } else if let integration = snapshot.integration, !integration.hooksTrusted {
            hook = Diagnosis(field: Self.field(
                .hook,
                value: .diagnosticUntrusted,
                action: .diagnosticActionReviewHooks,
                language: language
            ), issue: .diagnosticIssueHookConsent)
        } else if snapshot.integration == nil {
            hook = Diagnosis(field: Self.field(
                .hook,
                value: .diagnosticUnavailable,
                action: .diagnosticActionRepair,
                language: language
            ))
        } else {
            hook = Diagnosis(field: Self.field(
                .hook,
                value: .diagnosticTrusted,
                language: language
            ))
        }

        let companion: Diagnosis
        switch snapshot.companion {
        case .running:
            companion = Diagnosis(field: Self.field(
                .companion,
                value: .diagnosticRunning,
                language: language
            ))
        case .stopped:
            companion = Diagnosis(field: Self.field(
                .companion,
                value: .diagnosticNotRunning,
                action: .diagnosticActionRepair,
                language: language
            ), issue: .diagnosticIssueCompanion)
        case .unavailable:
            companion = Diagnosis(field: Self.field(
                .companion,
                value: .diagnosticUnavailable,
                action: .diagnosticActionRepair,
                language: language
            ))
        }

        let keyboard = Self.keyboardDiagnosis(snapshot.keyboard, language: language)

        var issues: [AppCopyKey] = []
        if snapshot.collectionFailed { issues.append(.diagnosticHealthUnavailable) }
        issues.append(contentsOf: [hook.issue, companion.issue, keyboard.issue].compactMap { $0 })
        if let integration = snapshot.integration, !integration.managedStatePresent {
            issues.append(.diagnosticIssueManagedState)
        }
        let errorHealth = issues.isEmpty
            ? AppCopy.value(.diagnosticNoErrors, language: language)
            : issues.map { AppCopy.value($0, language: language) }.joined(separator: "; ")

        let codexHost: DiagnosticField
        if let hosts = snapshot.codexHosts {
            codexHost = Self.field(
                .codexHost,
                value: Self.hostKey(hosts),
                action: hosts.isEmpty ? .diagnosticActionInstallCodex : nil,
                language: language
            )
        } else {
            codexHost = Self.field(
                .codexHost,
                value: .diagnosticUnavailable,
                action: .diagnosticActionRepair,
                language: language
            )
        }

        fields = [
            DiagnosticField(
                id: .appVersion,
                label: AppCopy.value(.diagnosticFieldAppVersion, language: language),
                value: snapshot.appVersion
            ),
            DiagnosticField(
                id: .macOS,
                label: AppCopy.value(.diagnosticFieldMacOS, language: language),
                value: snapshot.macOSVersion
            ),
            codexHost,
            hook.field,
            companion.field,
            keyboard.keyboard,
            keyboard.protocolReadback,
            DiagnosticField(
                id: .errorHealth,
                label: AppCopy.value(.diagnosticFieldErrorHealth, language: language),
                value: errorHealth
            ),
        ]
    }

    private struct Diagnosis {
        let field: DiagnosticField
        let issue: AppCopyKey?

        init(field: DiagnosticField, issue: AppCopyKey? = nil) {
            self.field = field
            self.issue = issue
        }
    }

    private struct KeyboardDiagnosis {
        let keyboard: DiagnosticField
        let protocolReadback: DiagnosticField
        let issue: AppCopyKey?
    }

    private static func keyboardDiagnosis(
        _ health: KeyboardHealth,
        language: AppLanguage
    ) -> KeyboardDiagnosis {
        switch health {
        case .unverified(let interfaces):
            KeyboardDiagnosis(
                keyboard: DiagnosticField(
                    id: .keyboard,
                    label: AppCopy.value(.diagnosticFieldKeyboard, language: language),
                    value: interfaces.map(\.diagnosticDescription).joined(separator: "\n"),
                    action: AppCopy.value(.keyboardUnverifiedDetail, language: language)
                ),
                protocolReadback: field(.protocolReadback, value: .keyboardUnverified, language: language),
                issue: .keyboardUnverified
            )
        case .disconnected:
            KeyboardDiagnosis(
                keyboard: field(
                    .keyboard,
                    value: .diagnosticDisconnected,
                    action: .diagnosticActionConnectKeyboard,
                    language: language
                ),
                protocolReadback: field(
                    .protocolReadback,
                    value: .diagnosticNotAvailable,
                    language: language
                ),
                issue: .diagnosticIssueDisconnected
            )
        case .unavailable:
            KeyboardDiagnosis(
                keyboard: field(
                    .keyboard,
                    value: .diagnosticUnavailable,
                    action: .diagnosticActionRepair,
                    language: language
                ),
                protocolReadback: field(
                    .protocolReadback,
                    value: .diagnosticNotAvailable,
                    language: language
                ),
                issue: .diagnosticIssueKeyboardUnavailable
            )
        case .ambiguous:
            KeyboardDiagnosis(
                keyboard: field(
                    .keyboard,
                    value: .diagnosticAmbiguous,
                    action: .diagnosticActionOneKeyboard,
                    language: language
                ),
                protocolReadback: field(
                    .protocolReadback,
                    value: .diagnosticNotAvailable,
                    language: language
                ),
                issue: .diagnosticIssueAmbiguous
            )
        case .connected(protocolHealthy: true):
            KeyboardDiagnosis(
                keyboard: field(.keyboard, value: .diagnosticConnected, language: language),
                protocolReadback: field(
                    .protocolReadback,
                    value: .diagnosticHealthy,
                    language: language
                ),
                issue: nil
            )
        case .connected(protocolHealthy: false):
            KeyboardDiagnosis(
                keyboard: field(.keyboard, value: .diagnosticConnected, language: language),
                protocolReadback: field(
                    .protocolReadback,
                    value: .diagnosticFailed,
                    action: .diagnosticActionProtocol,
                    language: language
                ),
                issue: .diagnosticIssueProtocol
            )
        }
    }

    private static func field(
        _ id: DiagnosticField.ID,
        value: AppCopyKey,
        action: AppCopyKey? = nil,
        language: AppLanguage
    ) -> DiagnosticField {
        DiagnosticField(
            id: id,
            label: AppCopy.value(labelKey(id), language: language),
            value: AppCopy.value(value, language: language),
            action: action.map { AppCopy.value($0, language: language) }
        )
    }

    private static func labelKey(_ id: DiagnosticField.ID) -> AppCopyKey {
        switch id {
        case .appVersion: .diagnosticFieldAppVersion
        case .macOS: .diagnosticFieldMacOS
        case .codexHost: .diagnosticFieldCodexHost
        case .hook: .diagnosticFieldHook
        case .companion: .diagnosticFieldCompanion
        case .keyboard: .diagnosticFieldKeyboard
        case .protocolReadback: .diagnosticFieldProtocol
        case .errorHealth: .diagnosticFieldErrorHealth
        }
    }

    private static func hostKey(_ hosts: Set<CodexHost>) -> AppCopyKey {
        switch (hosts.contains(.desktopApp), hosts.contains(.commandLine)) {
        case (true, true): .diagnosticHostBoth
        case (true, false): .setupDesktopHost
        case (false, true): .setupCommandLineHost
        case (false, false): .diagnosticNotInstalled
        }
    }
}

public enum DiagnosticExportError: Error, Equatable {
    case archiveFailed
}

public struct DiagnosticReportExporter: Sendable {
    private let archiveExecutableURL: URL

    public init(
        archiveExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ditto")
    ) {
        self.archiveExecutableURL = archiveExecutableURL
    }

    public func export(_ report: DiagnosticReport, to destination: URL) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appending(path: "keyphore-diagnostic-\(UUID().uuidString)")
        let stagedArchive = destination.deletingLastPathComponent().appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
            try? fileManager.removeItem(at: stagedArchive)
        }

        let reportURL = directory.appending(path: "diagnostic-report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)

        let process = Process()
        process.executableURL = archiveExecutableURL
        process.arguments = ["-c", "-k", "--norsrc", reportURL.path, stagedArchive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            throw DiagnosticExportError.archiveFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DiagnosticExportError.archiveFailed
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagedArchive)
        } else {
            try fileManager.moveItem(at: stagedArchive, to: destination)
        }
    }
}
