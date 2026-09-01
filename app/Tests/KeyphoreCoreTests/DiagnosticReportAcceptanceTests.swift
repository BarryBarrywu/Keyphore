import Foundation
import XCTest
import KeyphoreCore

final class DiagnosticReportAcceptanceTests: XCTestCase {
    func testPreviewShowsTheExactReviewedFieldsAndActionableFailures() throws {
        let report = DiagnosticReport(
            snapshot: DiagnosticSnapshot(
                appVersion: "0.1.0 (1)",
                macOSVersion: "macOS 15.6.1",
                codexHosts: [.desktopApp],
                integration: SetupIntegrationHealth(
                    pluginInstalled: true,
                    hooksTrusted: false,
                    companionRegistered: false,
                    managedStatePresent: true
                ),
                keyboard: .ambiguous
            ),
            language: .english
        )

        XCTAssertEqual(report.fields.map(\.id), [
            .appVersion,
            .macOS,
            .codexHost,
            .hook,
            .companion,
            .keyboard,
            .protocolReadback,
            .errorHealth,
        ])
        XCTAssertEqual(try report.field(.hook).value, "Untrusted")
        XCTAssertEqual(try report.field(.hook).action, "Review and allow Keyphore's Hooks.")
        XCTAssertEqual(try report.field(.companion).value, "Not running")
        XCTAssertEqual(try report.field(.companion).action, "Repair Keyphore setup.")
        XCTAssertEqual(try report.field(.keyboard).value, "Ambiguous device")
        XCTAssertEqual(
            try report.field(.keyboard).action,
            "Leave only the target Air65 V3 connected over wired USB."
        )
        XCTAssertEqual(try report.field(.protocolReadback).value, "Not available")
        XCTAssertEqual(
            try report.field(.errorHealth).value,
            "Hook consent required; Companion unavailable; multiple keyboards connected"
        )
    }

    func testDisconnectedAndProtocolReadbackFailureRemainDistinct() throws {
        let configured = SetupIntegrationHealth(
            pluginInstalled: true,
            hooksTrusted: true,
            companionRegistered: true,
            managedStatePresent: true
        )
        let disconnected = DiagnosticReport(
            snapshot: DiagnosticSnapshot(
                appVersion: "0.1.0 (1)",
                macOSVersion: "macOS 15.6.1",
                codexHosts: [.commandLine],
                integration: configured,
                keyboard: .disconnected
            ),
            language: .english
        )
        let readbackFailed = DiagnosticReport(
            snapshot: DiagnosticSnapshot(
                appVersion: "0.1.0 (1)",
                macOSVersion: "macOS 15.6.1",
                codexHosts: [.commandLine],
                integration: configured,
                keyboard: .connected(protocolHealthy: false)
            ),
            language: .english
        )

        XCTAssertEqual(try disconnected.field(.keyboard).value, "Disconnected")
        XCTAssertEqual(try disconnected.field(.protocolReadback).value, "Not available")
        XCTAssertEqual(try readbackFailed.field(.keyboard).value, "Connected")
        XCTAssertEqual(try readbackFailed.field(.protocolReadback).value, "Failed")
        XCTAssertNotEqual(
            try disconnected.field(.errorHealth).value,
            try readbackFailed.field(.errorHealth).value
        )
    }

    func testUnavailableInspectionIsNotMisreportedAsMissingComponents() throws {
        let report = DiagnosticReport(
            snapshot: DiagnosticSnapshot(
                appVersion: "0.1.0 (1)",
                macOSVersion: "macOS 15.6.1",
                codexHosts: nil,
                integration: nil,
                companion: .unavailable,
                keyboard: .unavailable
            ),
            language: .english
        )

        XCTAssertEqual(try report.field(.codexHost).value, "Unavailable")
        XCTAssertEqual(try report.field(.hook).value, "Unavailable")
        XCTAssertEqual(try report.field(.companion).value, "Unavailable")
        XCTAssertFalse(try report.field(.errorHealth).value.contains("not installed"))
        XCTAssertTrue(try report.field(.errorHealth).value.contains("health inspection unavailable"))
    }

    func testStoppedCompanionIsNotReportedAsRunningJustBecauseItIsRegistered() throws {
        let report = DiagnosticReport(
            snapshot: DiagnosticSnapshot(
                appVersion: "0.1.0 (1)",
                macOSVersion: "macOS 15.6.1",
                codexHosts: [.desktopApp],
                integration: SetupIntegrationHealth(
                    pluginInstalled: true,
                    hooksTrusted: true,
                    companionRegistered: true,
                    managedStatePresent: true
                ),
                companion: .stopped,
                keyboard: .connected(protocolHealthy: true)
            ),
            language: .english
        )

        XCTAssertEqual(try report.field(.companion).value, "Not running")
        XCTAssertTrue(try report.field(.errorHealth).value.contains("Companion unavailable"))
    }

    func testKeyboardDiagnosticHealthDistinguishesUnknownFromConfirmedDisconnection() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "keyphore-keyboard-diagnostic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KeyboardHealthStore(url: root.appending(path: "keyboard-health.json"))

        XCTAssertEqual(store.load(), .disconnected)
        XCTAssertEqual(store.loadDiagnosticHealth(), .unavailable)

        try store.save(.disconnected)

        XCTAssertEqual(store.loadDiagnosticHealth(), .disconnected)
    }

    func testFinalZipContainsOnlyTheReviewedReportAndNoPrivateNeighboringData() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "keyphore-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let privateValues = [
            "injected private prompt",
            "private assistant response",
            "private tool data",
            "barry",
            "/Users/barry/Documents/private-project",
        ]
        try privateValues.joined(separator: "\n").write(
            to: root.appending(path: "unrelated-codex-data.txt"),
            atomically: true,
            encoding: .utf8
        )
        let report = DiagnosticReport(
            snapshot: DiagnosticSnapshot(
                appVersion: "0.1.0 (1)",
                macOSVersion: "macOS 15.6.1",
                codexHosts: [.desktopApp, .commandLine],
                integration: .notConfigured,
                keyboard: .disconnected
            ),
            language: .simplifiedChinese
        )
        let zipURL = root.appending(path: "Keyphore-Diagnostics.zip")
        try Data("previous archive".utf8).write(to: zipURL)

        try DiagnosticReportExporter().export(report, to: zipURL)

        XCTAssertEqual(try unzip(arguments: ["-Z1", zipURL.path]), "diagnostic-report.json\n")
        let contents = try unzip(arguments: ["-p", zipURL.path, "diagnostic-report.json"])
        for privateValue in privateValues {
            XCTAssertFalse(contents.contains(privateValue))
        }
        for fieldID in DiagnosticField.ID.allCases {
            XCTAssertTrue(contents.contains("\"id\":\"\(fieldID.rawValue)\""))
        }
        XCTAssertTrue(contents.contains("\"language\":\"zh-Hans\""))
        XCTAssertTrue(contents.contains("Keyphore 不会自动上传此报告"))
        let archive = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contents.utf8)) as? [String: Any]
        )
        let fields = try XCTUnwrap(archive["fields"] as? [[String: Any]])
        let keyboard = try XCTUnwrap(fields.first { $0["id"] as? String == "keyboard" })
        let hook = try XCTUnwrap(fields.first { $0["id"] as? String == "hook" })
        XCTAssertEqual(keyboard["value"] as? String, "未连接")
        XCTAssertEqual(keyboard["action"] as? String, "请通过有线 USB 连接一把 Air65 V3。")
        XCTAssertEqual(hook["value"] as? String, "未安装")
        XCTAssertEqual(hook["action"] as? String, "请配置 Keyphore。")
    }

    func testFailedExportPreservesAnExistingDestination() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "keyphore-existing-diagnostic-\(UUID().uuidString).zip")
        let existing = Data("existing archive".utf8)
        try existing.write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        let report = DiagnosticReport(
            snapshot: DiagnosticSnapshot(
                appVersion: "0.1.0 (1)",
                macOSVersion: "macOS 15.6.1",
                codexHosts: [],
                integration: .notConfigured,
                keyboard: .disconnected
            ),
            language: .english
        )
        let exporter = DiagnosticReportExporter(
            archiveExecutableURL: URL(fileURLWithPath: "/nonexistent/keyphore-ditto")
        )

        XCTAssertThrowsError(try exporter.export(report, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), existing)
    }

    private func unzip(arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

private extension DiagnosticReport {
    func field(_ id: DiagnosticField.ID) throws -> DiagnosticField {
        try XCTUnwrap(fields.first { $0.id == id })
    }
}
