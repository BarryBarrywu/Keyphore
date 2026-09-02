import AppKit

@MainActor
struct ForegroundWindowAction {
    private let activateApplication: () -> Void

    init(activateApplication: @escaping () -> Void) {
        self.activateApplication = activateApplication
    }

    static let live = ForegroundWindowAction {
        NSApp.activate(ignoringOtherApps: true)
    }

    func activate() {
        activateApplication()
    }

    func open(_ presentation: () -> Void) {
        activate()
        presentation()
    }
}
