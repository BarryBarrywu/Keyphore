import XCTest
import KeyphoreCore

final class DefaultSignalProfileTests: XCTestCase {
    func testLocalProfileStartsWithVerifiedSignalDefaults() {
        let profile = LocalProfile.default

        XCTAssertEqual(profile.execution, SignalAppearance(
            isVisible: true,
            color: SignalColor(red: 0, green: 0, blue: 255),
            brightness: .full,
            pattern: .steady
        ))
        XCTAssertEqual(profile.attention, SignalAppearance(
            isVisible: true,
            color: SignalColor(red: 255, green: 132, blue: 0),
            brightness: .full,
            pattern: .steady
        ))
        XCTAssertEqual(profile.completion, SignalAppearance(
            isVisible: true,
            color: SignalColor(red: 0, green: 255, blue: 0),
            brightness: .full,
            pattern: .steady
        ))
        XCTAssertEqual(profile.completionDisplayDuration, .fiveSeconds)
        XCTAssertEqual(profile.signalOff, .off)
    }

    func testProfileValueTypesRejectOutOfRangeValues() {
        XCTAssertNil(SignalBrightness(percent: 0))
        XCTAssertNil(SignalBrightness(percent: 101))
        XCTAssertNil(CompletionDisplayDuration(seconds: 0))
        XCTAssertNil(CompletionDisplayDuration(seconds: 61))
    }
}
