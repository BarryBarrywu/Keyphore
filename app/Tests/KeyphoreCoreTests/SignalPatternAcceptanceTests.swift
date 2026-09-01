import Foundation
import KeyphoreCore
import XCTest

final class SignalPatternAcceptanceTests: XCTestCase {
    func testSlowFlashingUsesOneSecondLitAndUnlitPhasesWithAControllableClock() throws {
        let fixture = try PatternFixture(pattern: .slowFlashing)

        try fixture.companion.sync(at: .milliseconds(0))
        try fixture.companion.sync(at: .milliseconds(999))
        try fixture.companion.sync(at: .milliseconds(1_000))
        try fixture.companion.sync(at: .milliseconds(1_999))
        try fixture.companion.sync(at: .milliseconds(2_000))

        XCTAssertEqual(
            fixture.lighting.behaviors,
            [.signal(fixture.steadyExecution), .off, .signal(fixture.steadyExecution)]
        )
    }

    func testCompanionUsesProfileChangesWithoutRestarting() throws {
        let fixture = try PatternFixture(pattern: .steady)
        try fixture.companion.sync(at: .milliseconds(0))
        let updated = LocalProfile(
            execution: SignalAppearance(
                isVisible: true,
                color: SignalColor(red: 9, green: 8, blue: 7),
                brightness: SignalBrightness(percent: 42)!,
                pattern: .steady
            ),
            attention: fixture.profile.attention,
            completion: fixture.profile.completion,
            completionDisplayDuration: fixture.profile.completionDisplayDuration
        )

        try fixture.profileStore.save(updated)
        try fixture.companion.sync(at: .milliseconds(1))

        XCTAssertEqual(fixture.lighting.behaviors, [
            .signal(fixture.profile.execution),
            .signal(updated.execution),
        ])
    }
}

private final class PatternFixture {
    let directory: URL
    let statusStore: DurableStatusStore
    let profileStore: LocalProfileStore
    let profile: LocalProfile
    let lighting = PatternLightingAdapter()
    let companion: KeyphoreCompanion

    var steadyExecution: SignalAppearance {
        SignalAppearance(
            isVisible: profile.execution.isVisible,
            color: profile.execution.color,
            brightness: profile.execution.brightness,
            pattern: .steady
        )
    }

    init(pattern: SignalPattern) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        statusStore = DurableStatusStore(url: directory.appending(path: "status.json"))
        profileStore = LocalProfileStore(url: directory.appending(path: "profile.json"))
        let defaults = LocalProfile.default
        profile = LocalProfile(
            execution: SignalAppearance(
                isVisible: true,
                color: defaults.execution.color,
                brightness: defaults.execution.brightness,
                pattern: pattern
            ),
            attention: defaults.attention,
            completion: defaults.completion,
            completionDisplayDuration: defaults.completionDisplayDuration
        )
        try profileStore.save(profile)
        try statusStore.recordSignal(
            ownerID: SignalOwnerID(product: "codex", sessionID: "session", agentID: "main"),
            turnID: "turn",
            signal: .execution,
            expiresAt: .milliseconds(3_600_000),
            replacingSession: true,
            lockBudget: .milliseconds(100)
        )
        companion = KeyphoreCompanion(
            store: statusStore,
            profileProvider: { [profileStore] in try profileStore.load() },
            lighting: lighting
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class PatternLightingAdapter: CompanionLightingApplying {
    private(set) var behaviors: [LightingBehavior] = []

    func apply(_ behavior: LightingBehavior) throws {
        behaviors.append(behavior)
    }
}
