import AppKit
import KeyphoreCore
import SwiftUI
import XCTest

@MainActor
final class PopoverLayoutTests: XCTestCase {
    func testDisconnectedKeyboardUsesGenericPresentation() {
        let state = KeyphoreAppState(environment: ["KEYPHORE_ACCEPTANCE_FIXTURE": "configured"])
        let popover = KeyphorePopover(state: state)

        XCTAssertTrue(popover.usesGenericKeyboardPresentation)
    }

    func testLocalizedPanelsFitTheirWidthAndAttachPreviews() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        for choice in AppLanguageChoice.allCases where choice != .system {
            var arguments = previous
            arguments["app.language"] = choice.rawValue
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            let state = KeyphoreAppState(environment: ["KEYPHORE_ACCEPTANCE_FIXTURE": "ready-attention"])
            let popover = NSHostingController(rootView: KeyphorePopover(state: state))
            let size = popover.sizeThatFits(in: NSSize(width: 392, height: 0))
            XCTAssertEqual(size.width, 392, accuracy: 1)
            XCTAssertGreaterThanOrEqual(size.height, 350)
            XCTAssertLessThanOrEqual(size.height, 470, "\(choice)")
            attach(popover.view, size: size, name: "\(choice)-panel")
            for tab in [SettingsTab.general, .about] {
                state.selectedSettingsTab = tab
                let settings = NSHostingController(rootView: SignalSettingsView(state: state, checkForUpdates: {}))
                let fitted = settings.sizeThatFits(in: NSSize(width: 480, height: 640))
                XCTAssertEqual(fitted.width, 480, accuracy: 1)
                attach(settings.view, size: NSSize(width: 480, height: 640), name: "\(choice)-\(tab)")
            }
        }
    }

    private func attach(_ view: NSView, size: NSSize, name: String) {
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Could not render \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPopoverMapsEveryAppAppearanceToAColorScheme() {
        XCTAssertNil(AppAppearance.system.preferredColorScheme)
        XCTAssertEqual(AppAppearance.dark.preferredColorScheme, .dark)
        XCTAssertEqual(AppAppearance.light.preferredColorScheme, .light)
    }

    func testMenuBarPanelRetainsKeyboardSpaceUnderCompressedHeightProposal() {
        for fixture in ["ready-execution", "ready-attention", "ready-completion", "configured", "ready-off"] {
            let state = KeyphoreAppState(environment: ["KEYPHORE_ACCEPTANCE_FIXTURE": fixture])
            let hosting = NSHostingController(rootView: KeyphorePopover(state: state))

            let size = hosting.sizeThatFits(in: NSSize(width: 392, height: 0))

            XCTAssertEqual(size.width, 392, accuracy: 1)
            XCTAssertGreaterThanOrEqual(size.height, 350, "The approved panel must reserve its 344 × 132 keyboard even during intrinsic sizing: \(fixture)")
            XCTAssertLessThanOrEqual(size.height, 370, "The approved status-first panel has no management footer: \(fixture)")
        }
    }
}
