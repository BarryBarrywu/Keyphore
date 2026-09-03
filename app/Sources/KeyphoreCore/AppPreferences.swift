import Foundation

public enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark
}

public enum AppLanguageChoice: String, CaseIterable, Sendable {
    case system, english, simplifiedChinese
}

public struct AppPreferences: Equatable, Sendable {
    public var appearance: AppAppearance
    public var language: AppLanguageChoice

    public init(appearance: AppAppearance = .system, language: AppLanguageChoice = .system) {
        self.appearance = appearance
        self.language = language
    }

    public func resolvedLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch language {
        case .english: .english
        case .simplifiedChinese: .simplifiedChinese
        case .system:
            Locale(identifier: preferredLanguages.first ?? "en").language.script?.identifier == "Hans"
                ? .simplifiedChinese : .english
        }
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
