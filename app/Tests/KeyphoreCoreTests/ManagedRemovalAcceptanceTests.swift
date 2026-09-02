import XCTest
@testable import KeyphoreCore

final class ManagedRemovalAcceptanceTests: XCTestCase {
    func testReviewListsEveryKeyphoreManagedComponentWithoutChangingInstallation() throws {
        let integration = RecordingManagedRemovalIntegration()
        let removal = ManagedRemoval(integration: integration)

        let snapshot = try removal.inspect()

        XCTAssertEqual(snapshot.status, .reviewRequired)
        XCTAssertEqual(snapshot.components, Set(ManagedRemovalComponent.allCases))
        XCTAssertEqual(integration.actions, [])
    }

    func testConfirmedRemovalTurnsSignalOffBeforeRemovingOnlyManagedComponents() throws {
        let integration = RecordingManagedRemovalIntegration()
        let removal = ManagedRemoval(integration: integration)

        let snapshot = try removal.removeAfterConfirmation()

        XCTAssertEqual(snapshot.status, .completed)
        XCTAssertEqual(
            integration.actions,
            [
                .begin,
                .signalOff,
                .disableHooks,
                .removeCompanionAndBackgroundRegistration,
                .removePluginAndHooks,
                .removeLocalProfileAndManagedRuntimeState,
                .verify,
                .complete,
            ]
        )
        XCTAssertEqual(integration.unrelatedState, "preserved")
    }

    func testInterruptedRemovalReopensAsRepairableAndCanResume() throws {
        let integration = RecordingManagedRemovalIntegration(failsOnceAtPluginRemoval: true)
        let removal = ManagedRemoval(integration: integration)

        XCTAssertThrowsError(try removal.removeAfterConfirmation())
        XCTAssertEqual(try removal.inspect().status, .repairRequired)

        XCTAssertEqual(try removal.removeAfterConfirmation().status, .completed)
        XCTAssertEqual(integration.unrelatedState, "preserved")
    }
}

private final class RecordingManagedRemovalIntegration: ManagedRemovalIntegrating {
    enum Action: Equatable {
        case begin
        case signalOff
        case disableHooks
        case removeCompanionAndBackgroundRegistration
        case removePluginAndHooks
        case removeLocalProfileAndManagedRuntimeState
        case verify
        case complete
    }

    private(set) var actions: [Action] = []
    private(set) var status = ManagedRemovalStatus.reviewRequired
    private var failsOnceAtPluginRemoval: Bool
    let unrelatedState = "preserved"

    init(failsOnceAtPluginRemoval: Bool = false) {
        self.failsOnceAtPluginRemoval = failsOnceAtPluginRemoval
    }

    func inspectManagedRemoval() throws -> ManagedRemovalStatus { status }

    func beginManagedRemoval() throws {
        actions.append(.begin)
        status = .repairRequired
    }

    func requestSignalOffForRemoval() throws { actions.append(.signalOff) }
    func disableOwnedHooksForRemoval() throws { actions.append(.disableHooks) }

    func removeCompanionAndBackgroundRegistration() throws {
        actions.append(.removeCompanionAndBackgroundRegistration)
    }

    func removePluginAndHooks() throws {
        actions.append(.removePluginAndHooks)
        if failsOnceAtPluginRemoval {
            failsOnceAtPluginRemoval = false
            throw ManagedRemovalError.incomplete
        }
    }

    func removeLocalProfileAndManagedRuntimeState() throws {
        actions.append(.removeLocalProfileAndManagedRuntimeState)
    }

    func verifyManagedRemoval() throws -> Bool {
        actions.append(.verify)
        return true
    }

    func completeManagedRemoval() throws {
        actions.append(.complete)
        status = .completed
    }
}
