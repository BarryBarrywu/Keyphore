import Darwin
import Foundation

public enum KeyboardSelectionFailure: String, Codable, Sendable, Error {
    case notFound, ambiguous, oldTargetUnavailable, oldTargetOffFailed
    case unsupportedSelection, discoveryFailed, stateUnavailable
}

public enum KeyboardSelectionPhase: String, Codable, Sendable {
    case applied, pending, blocked
}

public struct KeyboardInventoryEntry: Codable, Equatable, Sendable {
    public let model: SupportedKeyboardModel
    public let count: Int
    public init(model: SupportedKeyboardModel, count: Int) { self.model = model; self.count = count }
}

public struct KeyboardSelectionSnapshot: Codable, Equatable, Sendable {
    public let desiredModel: SupportedKeyboardModel?
    public let activeModel: SupportedKeyboardModel?
    public let inventory: [KeyboardInventoryEntry]
    public let phase: KeyboardSelectionPhase
    public let failure: KeyboardSelectionFailure?
    public let observedAt: StatusTimestamp

    public init(desiredModel: SupportedKeyboardModel?, activeModel: SupportedKeyboardModel?,
                inventory: [KeyboardInventoryEntry], phase: KeyboardSelectionPhase,
                failure: KeyboardSelectionFailure? = nil, observedAt: StatusTimestamp = .now) {
        self.desiredModel = desiredModel
        self.activeModel = activeModel
        self.inventory = inventory
        self.phase = phase
        self.failure = failure
        self.observedAt = observedAt
    }
}

public final class KeyboardSelectionStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public var lockURL: URL { url.deletingPathExtension().appendingPathExtension("lock") }

    private struct Preference: Codable { let model: SupportedKeyboardModel? }

    public func load() throws -> SupportedKeyboardModel? {
        let model: SupportedKeyboardModel?
        do { model = try JSONDecoder().decode(Preference.self, from: Data(contentsOf: url)).model }
        catch CocoaError.fileReadNoSuchFile { return nil }
        try Self.validate(model)
        return model
    }

    public func save(_ model: SupportedKeyboardModel?) throws {
        try Self.validate(model)
        try withLock { try write(model) }
    }

    // Only discard the preference observed before discovery, never a newer user choice.
    @discardableResult
    func clear(ifUnchanged expected: SupportedKeyboardModel) throws -> Bool {
        try withLock {
            guard try load() == expected else { return false }
            try write(nil)
            return true
        }
    }

    private func write(_ model: SupportedKeyboardModel?) throws {
        try JSONEncoder().encode(Preference(model: model)).write(to: url, options: .atomic)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw KeyboardSelectionFailure.stateUnavailable }
        defer { close(descriptor) }
        let started = ContinuousClock.now
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN,
                  started.duration(to: .now) < .milliseconds(100) else {
                throw KeyboardSelectionFailure.stateUnavailable
            }
            usleep(1_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    static func validate(_ model: SupportedKeyboardModel?) throws {
        if let model, !SupportedKeyboardModel.selectableModels.contains(model) {
            throw KeyboardSelectionFailure.unsupportedSelection
        }
    }
}

public final class KeyboardSelectionSnapshotStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load(at now: StatusTimestamp = .now) -> KeyboardSelectionSnapshot? {
        guard let record = try? JSONDecoder().decode(KeyboardSelectionSnapshot.self, from: Data(contentsOf: url)),
              record.observedAt <= now, now.millisecondsSince1970 - record.observedAt.millisecondsSince1970 <= 3_000 else { return nil }
        return record
    }

    public func save(_ snapshot: KeyboardSelectionSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}

public struct LightingOwnershipRecord: Codable, Equatable, Sendable {
    public let model: SupportedKeyboardModel?
    public let zones: Set<LightingZone>
    public init(model: SupportedKeyboardModel?, zones: Set<LightingZone>) { self.model = model; self.zones = zones }
    public static let empty = LightingOwnershipRecord(model: nil, zones: [])
}

public protocol CompanionKeyboardSelecting: CompanionKeyboardIdentifying, AnyObject {
    func keyboardInventory() throws -> [KeyboardInventoryEntry]
    func selectTarget(_ model: SupportedKeyboardModel?) throws
}
