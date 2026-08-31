import XCTest
import KeyphoreCore

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
}
