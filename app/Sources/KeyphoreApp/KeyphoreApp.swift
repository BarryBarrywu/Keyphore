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
            CommandGroup(replacing: .appSettings) {
                Button(AppCopy.value(.settings)) { appDelegate.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
