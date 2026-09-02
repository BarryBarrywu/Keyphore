import AppKit
import KeyphoreCore

@MainActor
final class KeyphoreAppDelegate: NSObject, NSApplicationDelegate {
    var prepareToQuit: (() -> Bool)?
    var prepareForChangedHookUpdate: (() throws -> Void)?
    var recoverFromFailedChangedHookUpdate: (() throws -> Void)?
    private lazy var managedUpdates = ManagedUpdateController(
        prepareChangedHooks: { [weak self] in
            guard let prepare = self?.prepareForChangedHookUpdate else {
                throw ManagedUpdatePreparationError.runtimeUnavailable
            }
            try prepare()
        },
        recoverChangedHooks: { [weak self] in
            guard let recover = self?.recoverFromFailedChangedHookUpdate else {
                throw ManagedUpdatePreparationError.runtimeUnavailable
            }
            try recover()
        },
        presentError: { message in
            let alert = NSAlert()
            alert.messageText = AppCopy.value(.productName)
            alert.informativeText = message
            alert.runModal()
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        managedUpdates.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        prepareToQuit?() == false ? .terminateCancel : .terminateNow
    }

    func checkForUpdates() {
        managedUpdates.checkForUpdates()
    }
}

private enum ManagedUpdatePreparationError: Error {
    case runtimeUnavailable
}
