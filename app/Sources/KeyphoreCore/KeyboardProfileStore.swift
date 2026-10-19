import Foundation

/// Each physical model has its own LocalProfile. Selection changes never rewrite another model's settings.
public final class KeyboardProfileStore: @unchecked Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func url(for model: SupportedKeyboardModel) throws -> URL {
        let name: String
        switch model {
        case .air65V3: name = "air65-v3"
        case .air75V3: name = "air75-v3"
        case .air75V2: name = "air75-v2"
        default: throw KeyboardSelectionFailure.unsupportedSelection
        }
        return directory.appending(path: name + ".json")
    }

    public func load(for model: SupportedKeyboardModel) throws -> LocalProfile {
        try LocalProfileStore(url: url(for: model)).load()
    }

    public func save(_ profile: LocalProfile, for model: SupportedKeyboardModel) throws {
        try LocalProfileStore(url: url(for: model)).save(profile)
    }

    /// Hooks have no HID access. An absent/unreadable owner uses the duration default,
    /// rather than guessing a keyboard from the desired selection or dropping lifecycle events.
    public func completionDisplayDuration(ownership: LightingOwnershipStore) -> CompletionDisplayDuration {
        guard let model = try? ownership.load().model,
              let profile = try? load(for: model) else { return .fiveSeconds }
        return profile.completionDisplayDuration
    }
}
