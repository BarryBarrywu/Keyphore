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

@MainActor
struct ManagedRemovalFinishAction {
    private let terminateApplication: @MainActor @Sendable () -> Void

    init(terminateApplication: @escaping @MainActor @Sendable () -> Void) {
        self.terminateApplication = terminateApplication
    }

    static let live = ManagedRemovalFinishAction {
        NSApp.terminate(nil)
    }

    func perform(dismiss: () -> Void) {
        dismiss()
        DispatchQueue.main.async {
            terminateApplication()
        }
    }
}
