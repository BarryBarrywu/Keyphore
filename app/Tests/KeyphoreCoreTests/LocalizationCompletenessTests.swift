import XCTest
@testable import KeyphoreCore

final class LocalizationCompletenessTests: XCTestCase {
    func testAllResourceTablesContainEveryVisibleKeyWithoutUsingFallback() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KeyphoreCore/Resources")
        for language in AppLanguage.allCases {
            let data = try Data(contentsOf: resources.appending(path: "\(language.rawValue).lproj/Localizable.strings"))
            let table = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            )
            XCTAssertEqual(Set(table.keys), Set(AppCopyKey.allCases.map(\.rawValue)))
            for key in AppCopyKey.allCases {
                XCTAssertFalse(try XCTUnwrap(table[key.rawValue]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertEqual(AppCopy.value(key, language: language), table[key.rawValue])
            }
        }
    }

    func testVersionPlaceholderFormattingInEveryLanguage() {
        for language in AppLanguage.allCases {
            let formatted = String(format: AppCopy.value(.aboutVersion, language: language), "1.2.3", "456")
            XCTAssertTrue(formatted.contains("1.2.3"))
            XCTAssertTrue(formatted.contains("456"))
            XCTAssertFalse(formatted.contains("%@"))
        }
    }

    func testMissingTranslationOrLanguageDirectoryFallsBackToEnglish() throws {
        for includeChinese in [false, true] {
            let root = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).bundle")
            defer { try? FileManager.default.removeItem(at: root) }
            let english = root.appending(path: "Contents/Resources/en.lproj")
            try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
            try Data(#""action.quit" = "Quit Keyphore";"#.utf8)
                .write(to: english.appending(path: "Localizable.strings"))
            if includeChinese {
                let chinese = root.appending(path: "Contents/Resources/zh-Hans.lproj")
                try FileManager.default.createDirectory(at: chinese, withIntermediateDirectories: true)
                try Data(#""product.name" = "Keyphore";"#.utf8)
                    .write(to: chinese.appending(path: "Localizable.strings"))
            }
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "com.barrywu.keyphore.fallback.\(includeChinese)",
                "CFBundlePackageType": "BNDL", "CFBundleDevelopmentRegion": "en",
            ], format: .xml, options: 0).write(to: root.appending(path: "Contents/Info.plist"))
            let bundle = try XCTUnwrap(Bundle(url: root))
            XCTAssertEqual(AppCopy.value(.quit, language: .simplifiedChinese, resources: bundle), "Quit Keyphore")
        }
    }

    func testEnglishAndSimplifiedChineseCoverEveryVisibleString() {
        for key in AppCopyKey.allCases {
            for language in AppLanguage.allCases {
                let value = AppCopy.value(key, language: language)

                XCTAssertFalse(value.isEmpty, "Missing \(language) value for \(key.rawValue)")
                XCTAssertNotEqual(value, key.rawValue, "Untranslated \(language) value for \(key.rawValue)")
            }
        }
    }

    func testSimplifiedChineseResolvesTheNormalizedBundleDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "keyphore-localization-\(UUID().uuidString).bundle")
        let resources = root.appending(path: "Contents/Resources/zh-Hans.lproj")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(
            #""diagnostic.field.app_version" = "App 版本";"#.utf8
        ).write(to: resources.appending(path: "Localizable.strings"))
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.barrywu.keyphore.localization-fixture",
                "CFBundlePackageType": "BNDL",
                "CFBundleDevelopmentRegion": "en",
            ],
            format: .xml,
            options: 0
        ).write(to: root.appending(path: "Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))

        XCTAssertEqual(
            AppCopy.value(
                .diagnosticFieldAppVersion,
                language: .simplifiedChinese,
                resources: bundle
            ),
            "App 版本"
        )
    }
}
