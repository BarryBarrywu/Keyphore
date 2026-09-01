import XCTest
import KeyphoreCore

@MainActor
final class LifecycleAcceptanceTests: XCTestCase {
    func testDisconnectedConfiguredAppIsDistinctFromReadyApp() {
        let configured = KeyphoreLifecycle(
            health: FixedHealthAdapter(.configured(keyboard: .disconnected)),
            profiles: FixedProfileAdapter(.default),
            durableStatus: FixedDurableStatusAdapter(.signalOff),
            lighting: RecordingLightingAdapter(),
            runtime: RecordingRuntimeAdapter()
        ).refresh()

        let ready = KeyphoreLifecycle(
            health: FixedHealthAdapter(.configured(keyboard: .connected(protocolHealthy: true))),
            profiles: FixedProfileAdapter(.default),
            durableStatus: FixedDurableStatusAdapter(.signalOff),
            lighting: RecordingLightingAdapter(),
            runtime: RecordingRuntimeAdapter()
        ).refresh()

        XCTAssertEqual(configured.menuState, .configured)
        XCTAssertEqual(configured.health, .configured(keyboard: .disconnected))
        XCTAssertEqual(ready.menuState, .ready)
        XCTAssertEqual(ready.health, .configured(keyboard: .connected(protocolHealthy: true)))
    }

    func testReadyLifecycleEmitsConfiguredAppearanceForDurableSignal() {
        let lighting = RecordingLightingAdapter()
        let lifecycle = KeyphoreLifecycle(
            health: FixedHealthAdapter(.configured(keyboard: .connected(protocolHealthy: true))),
            profiles: FixedProfileAdapter(.default),
            durableStatus: FixedDurableStatusAdapter(.attention),
            lighting: lighting,
            runtime: RecordingRuntimeAdapter()
        )

        let snapshot = lifecycle.refresh()

        XCTAssertEqual(snapshot.currentSignal, .attention)
        XCTAssertEqual(lighting.behaviors, [.signal(LocalProfile.default.attention)])
    }

    func testHiddenAttentionRevealsActiveExecution() {
        let defaultProfile = LocalProfile.default
        let profile = LocalProfile(
            execution: defaultProfile.execution,
            attention: SignalAppearance(
                isVisible: false,
                color: defaultProfile.attention.color,
                brightness: defaultProfile.attention.brightness,
                pattern: defaultProfile.attention.pattern
            ),
            completion: defaultProfile.completion,
            completionDisplayDuration: defaultProfile.completionDisplayDuration
        )
        let lighting = RecordingLightingAdapter()
        let lifecycle = KeyphoreLifecycle(
            health: FixedHealthAdapter(.configured(keyboard: .connected(protocolHealthy: true))),
            profiles: FixedProfileAdapter(profile),
            durableStatus: FixedDurableStatusAdapter(.active([.attention, .execution])),
            lighting: lighting,
            runtime: RecordingRuntimeAdapter()
        )

        let snapshot = lifecycle.refresh()

        XCTAssertEqual(snapshot.currentSignal, .execution)
        XCTAssertEqual(lighting.behaviors, [.signal(profile.execution)])
    }

    func testQuitClosesGateBeforeDisablingOnlyOwnedRuntimeAndSignalSurface() throws {
        let runtime = RecordingRuntimeAdapter()
        let lighting = RecordingLightingAdapter()
        let lifecycle = KeyphoreLifecycle(
            health: FixedHealthAdapter(.configured(keyboard: .disconnected)),
            profiles: FixedProfileAdapter(.default),
            durableStatus: FixedDurableStatusAdapter(.execution),
            lighting: lighting,
            runtime: runtime
        )

        try lifecycle.quit()

        XCTAssertEqual(
            runtime.actions,
            [.activateQuitGate, .disableOwnedHooks, .clearManagedRuntimeState, .requestSignalOff, .stopCompanion]
        )
        XCTAssertTrue(lighting.behaviors.isEmpty)
    }

    func testReopenStartsFreshAndRestoresOnlyTrustedUnchangedHooks() throws {
        let runtime = RecordingRuntimeAdapter(hooksMatchReviewedRelease: true)
        let lifecycle = KeyphoreLifecycle(
            health: FixedHealthAdapter(.configured(keyboard: .disconnected)),
            profiles: FixedProfileAdapter(.default),
            durableStatus: FixedDurableStatusAdapter(.execution),
            lighting: RecordingLightingAdapter(),
            runtime: runtime
        )

        let outcome = try lifecycle.reopen()

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(
            runtime.actions,
            [.clearManagedRuntimeState, .enableOwnedHooksIfTrusted, .startCompanion, .requestSignalOff, .clearQuitGate]
        )
    }

    func testReopenKeepsChangedHookDefinitionsDisabledAndQuitGateClosed() throws {
        let runtime = RecordingRuntimeAdapter(hooksMatchReviewedRelease: false)
        let lifecycle = KeyphoreLifecycle(
            health: FixedHealthAdapter(.configured(keyboard: .disconnected)),
            profiles: FixedProfileAdapter(.default),
            durableStatus: FixedDurableStatusAdapter(.execution),
            lighting: RecordingLightingAdapter(),
            runtime: runtime
        )

        let outcome = try lifecycle.reopen()

        XCTAssertEqual(outcome, .renewedConsentRequired)
        XCTAssertEqual(
            runtime.actions,
            [.clearManagedRuntimeState, .enableOwnedHooksIfTrusted]
        )
    }
}

private struct FixedHealthAdapter: KeyphoreHealthProviding {
    let health: KeyphoreHealth

    init(_ health: KeyphoreHealth) {
        self.health = health
    }

    func currentHealth() -> KeyphoreHealth { health }
}

private struct FixedProfileAdapter: LocalProfileProviding {
    let profile: LocalProfile

    init(_ profile: LocalProfile) {
        self.profile = profile
    }

    func currentProfile() -> LocalProfile { profile }
}

private struct FixedDurableStatusAdapter: DurableStatusProviding {
    let outcome: DurableStatusOutcome

    init(_ outcome: DurableStatusOutcome) {
        self.outcome = outcome
    }

    func currentOutcome() -> DurableStatusOutcome { outcome }
}

private final class RecordingLightingAdapter: LightingEmitting {
    private(set) var behaviors: [LightingBehavior] = []

    func emit(_ behavior: LightingBehavior) {
        behaviors.append(behavior)
    }
}

private final class RecordingRuntimeAdapter: KeyphoreRuntimeManaging {
    enum Action: Equatable {
        case activateQuitGate
        case disableOwnedHooks
        case stopCompanion
        case clearManagedRuntimeState
        case requestSignalOff
        case enableOwnedHooksIfTrusted
        case startCompanion
        case clearQuitGate
    }

    private(set) var actions: [Action] = []
    private let hooksMatchReviewedRelease: Bool

    init(hooksMatchReviewedRelease: Bool = true) {
        self.hooksMatchReviewedRelease = hooksMatchReviewedRelease
    }

    func activateQuitGate() {
        actions.append(.activateQuitGate)
    }

    func disableOwnedHooks() {
        actions.append(.disableOwnedHooks)
    }

    func stopCompanion() {
        actions.append(.stopCompanion)
    }

    func clearManagedRuntimeState() {
        actions.append(.clearManagedRuntimeState)
    }

    func requestSignalOff() {
        actions.append(.requestSignalOff)
    }

    func enableOwnedHooksIfTrusted() -> Bool {
        actions.append(.enableOwnedHooksIfTrusted)
        return hooksMatchReviewedRelease
    }

    func startCompanion() {
        actions.append(.startCompanion)
    }

    func clearQuitGate() {
        actions.append(.clearQuitGate)
    }
}
