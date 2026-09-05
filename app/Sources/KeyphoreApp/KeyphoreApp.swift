import SwiftUI
import KeyphoreCore

@main
struct KeyphoreApp: App {
    @NSApplicationDelegateAdaptor(KeyphoreAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SignalSettingsView(state: appDelegate.state, checkForUpdates: appDelegate.checkForUpdates)
        }
        .defaultSize(width: 480, height: 640)
        .commands {
            KeyphoreCommands(state: appDelegate.state, showSettings: appDelegate.showSettings)
        }
    }
}

private struct KeyphoreCommands: Commands {
    @ObservedObject var state: KeyphoreAppState
    let showSettings: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(AppCopy.value(.settings, language: state.preferences.resolvedLanguage()), action: showSettings)
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
