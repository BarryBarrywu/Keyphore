import Foundation
import KeyphoreCore
import XCTest

final class LocalProfilePersistenceTests: XCTestCase {
    func testFreshStoreRestoresTheDefaultSignalProfile() throws {
        let fixture = try ProfileStoreFixture()

        XCTAssertEqual(try fixture.store.load(), .default)
    }

    func testEachSignalAppearanceAndCompletionDurationPersistLocally() throws {
        let fixture = try ProfileStoreFixture()
        let profile = LocalProfile(
            execution: appearance(visible: false, red: 1, green: 2, blue: 3, brightness: 11, pattern: .backlightBreathing),
            attention: appearance(visible: true, red: 4, green: 5, blue: 6, brightness: 22, pattern: .backlightStatic),
            completion: appearance(visible: true, red: 7, green: 8, blue: 9, brightness: 33, pattern: .backlightBreathing),
            idle: appearance(visible: true, red: 10, green: 11, blue: 12, brightness: 44, pattern: .backlightWave),
            completionDisplayDuration: CompletionDisplayDuration(seconds: 60)!
        )

        try fixture.store.save(profile)

        XCTAssertEqual(try fixture.store.load(), profile)
    }

    func testPersistedProfileRequiresIdleField() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalProfile.default)) as? [String: Any])
        object.removeValue(forKey: "idle")
        XCTAssertThrowsError(try JSONDecoder().decode(LocalProfile.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testZeroBrightnessIsOffAndCompletionDurationRemainsBounded() {
        XCTAssertNotNil(SignalBrightness(percent: 0))
        XCTAssertNil(CompletionDisplayDuration(seconds: 0))
        XCTAssertNil(CompletionDisplayDuration(seconds: 61))
    }

    func testHookUsesTheLatestPersistedCompletionDuration() throws {
        let fixture = try ProfileStoreFixture()
        let statusStore = DurableStatusStore(url: fixture.directory.appending(path: "status.json"))
        let defaults = LocalProfile.default
        try fixture.store.save(
            LocalProfile(
                execution: defaults.execution,
                attention: defaults.attention,
                completion: defaults.completion,
                completionDisplayDuration: CompletionDisplayDuration(seconds: 60)!
            )
        )
        let hook = ProductionHookHandler(
            store: statusStore,
            completionDurationProvider: { try fixture.store.load().completionDisplayDuration }
        )

        try hook.handle(
            Data("""
            {"hook_event_name":"Stop","session_id":"session","turn_id":"turn"}
            """.utf8),
            receivedAt: .milliseconds(1_000)
        )

        XCTAssertEqual(try statusStore.load().owners.first?.expiresAt, .milliseconds(61_000))
    }

    func testMalformedProfileCannotPreventStopFromPersistingCompletion() throws {
        let fixture = try ProfileStoreFixture()
        try Data("not-json".utf8).write(to: fixture.store.url)
        let statusStore = DurableStatusStore(url: fixture.directory.appending(path: "status.json"))
        let hook = ProductionHookHandler(
            store: statusStore,
            completionDurationProvider: { fixture.store.loadOrDefault().completionDisplayDuration }
        )

        try hook.handle(
            Data("""
            {"hook_event_name":"Stop","session_id":"session","turn_id":"turn"}
            """.utf8),
            receivedAt: .milliseconds(1_000)
        )

        XCTAssertEqual(try statusStore.load().owners.first?.expiresAt, .milliseconds(6_000))
    }

    private func appearance(
        visible: Bool,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        brightness: UInt8,
        pattern: NativeLightingEffect
    ) -> SignalAppearance {
        SignalAppearance(isVisible: visible, backlight: ZoneAppearance(effect: pattern, color: SignalColor(red: red, green: green, blue: blue), colorMode: .multicolor, brightness: SignalBrightness(percent: brightness)!, speed: LightingSpeed(level: 1)!), strip: LocalProfile.default.completion.strip)
    }
}

private final class ProfileStoreFixture {
    let directory: URL
    let store: LocalProfileStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = LocalProfileStore(url: directory.appending(path: "profile.json"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
