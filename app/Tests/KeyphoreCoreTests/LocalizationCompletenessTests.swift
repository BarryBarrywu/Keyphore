import XCTest
@testable import KeyphoreCore

final class LocalizationCompletenessTests: XCTestCase {
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
