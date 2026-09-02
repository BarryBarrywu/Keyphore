import XCTest

@MainActor
final class ForegroundWindowActionTests: XCTestCase {
    func testOpeningAWindowActivatesKeyphoreBeforePresentingIt() {
        var events: [String] = []
        let action = ForegroundWindowAction {
            events.append("activate")
        }

        action.open {
            events.append("open")
        }

        XCTAssertEqual(events, ["activate", "open"])
    }

    func testSettingsLinkCanActivateKeyphoreWithoutOpeningASecondWindow() {
        var activationCount = 0
        let action = ForegroundWindowAction {
            activationCount += 1
        }

        action.activate()

        XCTAssertEqual(activationCount, 1)
    }
}
