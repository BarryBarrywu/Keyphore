import AppKit
import SwiftUI
import Combine
import KeyphoreCore

@MainActor
final class KeyphoreAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state: KeyphoreAppState

    override init() {
        state = KeyphoreAppState()
        super.init()
    }

    init(state: KeyphoreAppState) {
        self.state = state
        super.init()
    }
    private var statusItem: NSStatusItem?
    private let statusPopover = NSPopover()
    private let statusMenu = NSMenu()
    private var settingsWindow: NSWindow?
    private var stateSubscription: AnyCancellable?
    private var accessibilitySubscription: AnyCancellable?
    private var appliedAppearance: AppAppearance?
    var startupInProgress: (() -> Bool)?
    var waitForStartup: (() async -> Void)?
    private var terminationPending = false
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
            ForegroundWindowAction.live.activate()
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = AppCopy.value(.productName)
                alert.informativeText = message
                alert.runModal()
            }
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareToQuit = state.prepareToQuit
        prepareForChangedHookUpdate = state.prepareForChangedHookUpdate
        recoverFromFailedChangedHookUpdate = state.recoverFromFailedChangedHookUpdate
        state.openSettings = { [weak self] in self?.showSettings() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        statusMenu.delegate = self
        statusPopover.behavior = .transient
        updatePopoverMotion()
        accessibilitySubscription = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePopoverMotion() }
        statusPopover.contentViewController = NSHostingController(rootView: KeyphorePopover(state: state))
        updateStatusItem()
        stateSubscription = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
        startupInProgress = { [weak state] in state?.isStarting == true }
        waitForStartup = { [weak state] in await state?.waitForStartup() }
        DispatchQueue.main.async { [weak self] in self?.showStatusPopover() }
        Task {
            await state.waitForStartup()
            managedUpdates.start()
        }
    }

    private func updateStatusItem() {
        statusItem?.button?.image = state.currentSignalPresentation.menuBarImage
        statusItem?.button?.setAccessibilityLabel(state.currentSignalPresentation.menuBarAccessibilityLabel)
        guard appliedAppearance != state.preferences.appearance else { return }
        appliedAppearance = state.preferences.appearance
        switch state.preferences.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusPopover.performClose(nil)
            statusItem?.menu = statusMenu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else if statusPopover.isShown {
            statusPopover.performClose(nil)
        } else {
            showStatusPopover()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = menu.addItem(withTitle: AppCopy.value(.settings) + "…",
                                    action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        let about = menu.addItem(withTitle: AppCopy.value(.aboutMenu),
                                 action: #selector(openAboutFromMenu), keyEquivalent: "")
        about.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: AppCopy.value(.quit),
                                action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
    }

    @objc private func openSettingsFromMenu() { showSettings() }
    @objc private func openAboutFromMenu() {
        state.selectedSettingsTab = .about
        showSettings()
    }
    @objc private func quitFromMenu() {
        statusPopover.performClose(nil)
        NSApp.terminate(nil)
    }

    func showSettings() {
        statusPopover.performClose(nil)
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SignalSettingsView(
                state: state, checkForUpdates: checkForUpdates))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 480, height: 640))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.title = AppCopy.value(.settings)
        ForegroundWindowAction.live.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if startupInProgress?() == true {
            if !terminationPending {
                terminationPending = true
                Task {
                    await waitForStartup?()
                    terminationPending = false
                    NSApp.reply(toApplicationShouldTerminate: completeQuitPreparation())
                }
            }
            return .terminateLater
        }
        return completeQuitPreparation() ? .terminateNow : .terminateCancel
    }

    private func completeQuitPreparation() -> Bool {
        let prepared = prepareToQuit?() != false
        if !prepared { showStatusPopover() }
        return prepared
    }

    private func updatePopoverMotion() {
        statusPopover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func showStatusPopover() {
        guard let button = statusItem?.button, !statusPopover.isShown else { return }
        ForegroundWindowAction.live.activate()
        statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatusPopover()
        return false
    }

    func checkForUpdates() {
        managedUpdates.checkForUpdates()
    }
}

private enum ManagedUpdatePreparationError: Error {
    case runtimeUnavailable
}
