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
            Image(nsImage: state.currentSignalPresentation.menuBarImage)
                .accessibilityLabel(AppCopy.value(.productName))
                .onAppear {
                    appDelegate.prepareToQuit = state.prepareToQuit
                    appDelegate.prepareForChangedHookUpdate = state.prepareForChangedHookUpdate
                    appDelegate.recoverFromFailedChangedHookUpdate =
                        state.recoverFromFailedChangedHookUpdate
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SignalSettingsView(state: state)
        }

        Window(AppCopy.value(.diagnostics), id: "diagnostics") {
            DiagnosticsView(state: state)
        }
        .defaultSize(width: 560, height: 520)
    }
}
