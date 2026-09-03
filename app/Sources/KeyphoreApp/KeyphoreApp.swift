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
                    applyAppearance()
                    appDelegate.prepareToQuit = state.prepareToQuit
                    appDelegate.prepareForChangedHookUpdate = state.prepareForChangedHookUpdate
                    appDelegate.recoverFromFailedChangedHookUpdate =
                        state.recoverFromFailedChangedHookUpdate
                }
                .onChange(of: state.preferences.appearance) { _ in applyAppearance() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SignalSettingsView(state: state, checkForUpdates: appDelegate.checkForUpdates)
        }
        .defaultSize(width: 480, height: 740)
    }

    private func applyAppearance() {
        switch state.preferences.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
