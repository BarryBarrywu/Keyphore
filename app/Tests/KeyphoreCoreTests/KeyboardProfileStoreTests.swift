import XCTest
@testable import KeyphoreCore

final class KeyboardProfileStoreTests: XCTestCase {
    func testFreshV2ProfileIsMainOnlyAndEveryPresetHasSupportedCommands() throws {
        let f = try ProfileFixture()
        let profile = try f.profiles.load(for: .air75V2)
        XCTAssertEqual(profile, .default)
        XCTAssertEqual(profile.controlledZones, .backlight)
        for preset in LightingPreset.allCases {
            try VIALightingAdapter.validate(.signal(profile.appearance(forPreset: preset), controlledZones: profile.controlledZones))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.profiles.url(for: .air75V2).path))
    }

    func testModelFilesNeverReadOrOverwriteAnotherModelOrTheOldGlobalFile() throws {
        let f = try ProfileFixture()
        let v3 = withDuration(60).replacingControlledZones(.both)
        try f.profiles.save(v3, for: .air75V3)
        let original = try Data(contentsOf: f.profiles.url(for: .air75V3))
        try LocalProfileStore(url: f.directory.appending(path: "profile.json")).save(v3)
        XCTAssertEqual(try f.profiles.load(for: .air75V2), .default)
        let v2 = withDuration(17)
        try f.profiles.save(v2, for: .air75V2)
        XCTAssertEqual(try f.profiles.load(for: .air75V2), v2)
        XCTAssertEqual(try Data(contentsOf: f.profiles.url(for: .air75V3)), original)
        XCTAssertThrowsError(try f.profiles.load(for: .init(rawValue: "../profile")))
        try Data("invalid".utf8).write(to: f.profiles.url(for: .air75V2))
        XCTAssertThrowsError(try f.profiles.load(for: .air75V2))
        XCTAssertEqual(try f.profiles.load(for: .air75V3), v3)
    }

    func testHookCompletionDurationFollowsAppliedOwnerNotDesiredSelection() throws {
        let f = try ProfileFixture()
        try f.profiles.save(withDuration(60), for: .air75V3)
        try f.profiles.save(withDuration(17), for: .air75V2)
        let selection = KeyboardSelectionStore(url: f.directory.appending(path: "selection.json"))
        try selection.save(.air75V2)
        try f.ownership.save(LightingOwnershipRecord(model: .air75V3, zones: [.backlight, .strip]))
        let status = DurableStatusStore(url: f.directory.appending(path: "status.json"))
        let hook = ProductionHookHandler(store: status,
            completionDurationProvider: { f.profiles.completionDisplayDuration(ownership: f.ownership) })
        try hook.handle(Data(#"{"hook_event_name":"Stop","session_id":"v3","turn_id":"turn"}"#.utf8),
                        receivedAt: .milliseconds(1_000))
        XCTAssertEqual(try status.load().owners.first?.expiresAt, .milliseconds(61_000))
        try f.ownership.save(LightingOwnershipRecord(model: .air75V2, zones: [.backlight]))
        try hook.handle(Data(#"{"hook_event_name":"Stop","session_id":"v2","turn_id":"turn"}"#.utf8),
                        receivedAt: .milliseconds(2_000))
        XCTAssertEqual(try status.load().owners.first { $0.id.sessionID == "v2" }?.expiresAt, .milliseconds(19_000))
        try f.ownership.save(.empty)
        XCTAssertEqual(f.profiles.completionDisplayDuration(ownership: f.ownership), .fiveSeconds)
        try f.ownership.save(LightingOwnershipRecord(model: .air75V2, zones: []))
        try Data("invalid".utf8).write(to: f.profiles.url(for: .air75V2))
        try hook.handle(Data(#"{"hook_event_name":"Stop","session_id":"fallback","turn_id":"turn"}"#.utf8),
                        receivedAt: .milliseconds(3_000))
        XCTAssertEqual(try status.load().owners.first { $0.id.sessionID == "fallback" }?.expiresAt, .milliseconds(8_000))
    }

    private func withDuration(_ seconds: UInt8) -> LocalProfile {
        let profile = LocalProfile.default
        return LocalProfile(execution: profile.execution, attention: profile.attention, completion: profile.completion,
            idle: profile.idle, completionDisplayDuration: CompletionDisplayDuration(seconds: seconds)!,
            controlledZones: profile.controlledZones)
    }
}

private final class ProfileFixture {
    let directory: URL
    let profiles: KeyboardProfileStore
    let ownership: LightingOwnershipStore
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        profiles = KeyboardProfileStore(directory: directory.appending(path: "profiles"))
        ownership = LightingOwnershipStore(url: directory.appending(path: "ownership.json"))
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
