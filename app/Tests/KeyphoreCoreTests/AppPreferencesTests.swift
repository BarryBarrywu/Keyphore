import Foundation
import KeyphoreCore
import XCTest

final class AppPreferencesTests: XCTestCase {
    func testSystemLanguageResolvesSimplifiedChineseAndFallsBackToEnglish() {
        let preferences = AppPreferences()
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["zh-Hans-TW"]), .simplifiedChinese)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["en-US"]), .english)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["ja-JP"]), .english)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["zh-Hant-TW"]), .english)
    }

    func testAppearanceAndLanguagePersistWhenSettingsReopen() throws {
        let suite = "keyphore-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.load(), AppPreferences())

        store.save(AppPreferences(appearance: .dark, language: .simplifiedChinese))

        let reopened = AppPreferencesStore(defaults: defaults).load()
        XCTAssertEqual(reopened.appearance, .dark)
        XCTAssertEqual(reopened.language, .simplifiedChinese)
        XCTAssertEqual(reopened.resolvedLanguage(preferredLanguages: ["en-US"]), .simplifiedChinese)
    }
}
