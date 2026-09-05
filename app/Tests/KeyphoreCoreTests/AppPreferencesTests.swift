import Foundation
import KeyphoreCore
import XCTest

final class AppPreferencesTests: XCTestCase {
    func testSystemLanguageUsesFirstSupportedPreference() {
        let preferences = AppPreferences()
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["zh-Hans-TW"]), .simplifiedChinese)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["en-US"]), .english)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["zh-HK"]), .traditionalChinese)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["pt", "ko-KR", "en"]), .korean)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["fr-CA"]), .french)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["de-AT"]), .german)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["it-CH"]), .italian)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["es-MX"]), .spanish)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["pt", "ar"]), .english)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: []), .english)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["pt-BR", "ja-JP"]), .japanese)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["zh-Hant-TW"]), .traditionalChinese)
    }

    func testEveryManualLanguagePersistsAndOverridesSystemPreferences() throws {
        let suite = "keyphore-languages-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.rawValue)),
                       Set(["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "it", "es"]))
        for choice in AppLanguageChoice.allCases where choice != .system {
            store.save(AppPreferences(language: choice))
            let restored = AppPreferencesStore(defaults: defaults).load()
            XCTAssertEqual(restored.language, choice)
            XCTAssertEqual(restored.resolvedLanguage(preferredLanguages: ["pt", "en"]), choice.language)
        }
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
