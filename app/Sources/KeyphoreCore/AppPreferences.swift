import Foundation

public enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark
}

public enum AppLanguageChoice: String, CaseIterable, Sendable {
    case system, english, simplifiedChinese, traditionalChinese, japanese, korean, french, german, italian, spanish

    public var language: AppLanguage? {
        switch self {
        case .system: nil
        case .english: .english
        case .simplifiedChinese: .simplifiedChinese
        case .traditionalChinese: .traditionalChinese
        case .japanese: .japanese
        case .korean: .korean
        case .french: .french
        case .german: .german
        case .italian: .italian
        case .spanish: .spanish
        }
    }
}

public struct AppPreferences: Equatable, Sendable {
    public var appearance: AppAppearance
    public var language: AppLanguageChoice

    public init(appearance: AppAppearance = .system, language: AppLanguageChoice = .system) {
        self.appearance = appearance
        self.language = language
    }

    public func resolvedLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let selected = language.language { return selected }
        for identifier in preferredLanguages {
            let locale = Locale(identifier: identifier).language
            if locale.languageCode?.identifier == "zh" {
                return locale.script?.identifier == "Hant" ? .traditionalChinese : .simplifiedChinese
            }
            if let code = locale.languageCode?.identifier, let supported = AppLanguage(rawValue: code) {
                return supported
            }
        }
        return .english
    }
}

public struct AppPreferencesStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppPreferences {
        AppPreferences(
            appearance: defaults.string(forKey: "app.appearance").flatMap(AppAppearance.init) ?? .system,
            language: defaults.string(forKey: "app.language").flatMap(AppLanguageChoice.init) ?? .system
        )
    }

    public func save(_ preferences: AppPreferences) {
        defaults.set(preferences.appearance.rawValue, forKey: "app.appearance")
        defaults.set(preferences.language.rawValue, forKey: "app.language")
    }
}
