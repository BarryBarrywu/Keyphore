import AppKit
import SwiftUI
import KeyphoreCore

@main
struct KeyphoreApp: App {
    @NSApplicationDelegateAdaptor(KeyphoreAppDelegate.self) private var appDelegate
    @StateObject private var state = KeyphoreAppState()

    var body: some Scene {
        MenuBarExtra {
            KeyphorePopover(state: state)
        } label: {
            Image(systemName: state.menuBarSymbol)
                .accessibilityLabel(AppCopy.value(.productName))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SignalSettingsView(profile: state.snapshot.profile)
        }

        Window(AppCopy.value(.diagnostics), id: "diagnostics") {
            DiagnosticsView(snapshot: state.snapshot, menuState: state.menuState)
        }
        .defaultSize(width: 420, height: 240)
    }
}

final class KeyphoreAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
