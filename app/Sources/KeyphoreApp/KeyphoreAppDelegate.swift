import AppKit

final class KeyphoreAppDelegate: NSObject, NSApplicationDelegate {
    var prepareToQuit: (() -> Bool)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        prepareToQuit?() == false ? .terminateCancel : .terminateNow
    }
}
