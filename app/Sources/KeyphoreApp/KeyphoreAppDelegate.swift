import AppKit
import SwiftUI
import Combine
import Darwin
import KeyphoreCore

@MainActor
final class KeyphoreAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state: KeyphoreAppState
    private var instanceLock: KeyphoreAppInstanceLock?

    override init() {
        // Claim the runtime before state initialization can register a Companion or inspect hooks.
        do {
            instanceLock = try KeyphoreAppInstanceLock(url: KeyphoreRuntimePaths.supportDirectory()
                .appending(path: "app-instance.lock"))
        } catch KeyphoreAppInstanceLock.Failure.alreadyRunning {
            _ = Self.activateExistingInstance()
            exit(EXIT_SUCCESS)
        } catch {
            NSLog("Keyphore could not claim its App instance: %@", String(describing: error))
            exit(EXIT_FAILURE)
        }
        // A previously installed version may not participate in the instance lock yet.
        if Self.activateExistingInstance(outside: Bundle.main.bundleURL.resolvingSymlinksInPath()) { exit(EXIT_SUCCESS) }
        state = KeyphoreAppState()
        super.init()
    }

    private static func activateExistingInstance(outside currentBundle: URL? = nil) -> Bool {
        guard let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.barrywu.keyphore")
            .first(where: {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
                    && (currentBundle == nil || $0.bundleURL?.resolvingSymlinksInPath() != currentBundle)
            }) else {
            return false
        }
        existing.activate(options: [])
        // Activation alone does not deliver the reopen event that reveals the settings window.
        if let url = existing.bundleURL { _ = NSWorkspace.shared.open(url) }
        return true
    }

    init(state: KeyphoreAppState) {
        self.state = state
        super.init()
    }
    private var statusItem: NSStatusItem?
    private let statusPopover = NSPopover()
    private let statusMenu = NSMenu()
    private var keyboardSelectionMenu: NSMenu?
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
        settingsWindow?.title = AppCopy.value(.settings)
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
        state.refreshKeyboardSelection()
        if menu === keyboardSelectionMenu {
            populateKeyboardSelectionMenu(menu)
            return
        }
        menu.removeAllItems()
        menu.autoenablesItems = false
        if state.canSelectKeyboard {
            let keyboard = menu.addItem(withTitle: AppCopy.value(.keyboardSelectionTitle), action: nil, keyEquivalent: "")
            keyboard.identifier = NSUserInterfaceItemIdentifier("keyboard-selection")
            let submenu = NSMenu(title: keyboard.title)
            keyboardSelectionMenu = submenu
            submenu.delegate = self
            populateKeyboardSelectionMenu(submenu)
            keyboard.submenu = submenu
            menu.addItem(.separator())
        }
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

    private func populateKeyboardSelectionMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let active = menu.addItem(withTitle: AppCopy.value(.keyboardSelectionActive) + ": " + state.keyboardSelectionActiveLabel,
                                  action: nil, keyEquivalent: "")
        active.isEnabled = false
        if let key = state.keyboardSelectionMessageKey {
            menu.addItem(withTitle: AppCopy.value(key), action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        for option in state.keyboardSelectionOptions {
            let item = menu.addItem(withTitle: state.keyboardTargetLabel(option),
                                    action: #selector(selectKeyboardFromMenu(_:)), keyEquivalent: "")
            item.representedObject = option.id
            item.target = self
            item.state = option.model == state.desiredKeyboardModel ? .on : .off
            item.isEnabled = state.canRequestKeyboardSelection(option.model)
        }
    }

    @objc private func selectKeyboardFromMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        state.requestKeyboardSelection(value.isEmpty ? nil : SupportedKeyboardModel(rawValue: value))
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
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.minSize = NSSize(width: 1000, height: 700)
            window.setContentSize(NSSize(width: 1040, height: 760))
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
        state.refreshKeyboardSelection()
        ForegroundWindowAction.live.activate()
        statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func checkForUpdates() {
        managedUpdates.checkForUpdates()
    }
}

private enum ManagedUpdatePreparationError: Error {
    case runtimeUnavailable
}

// The descriptor stays alive for the App lifetime; never unlink a lock that another process may hold.
final class KeyphoreAppInstanceLock {
    enum Failure: Error, Equatable {
        case alreadyRunning
        case unavailable(Int32)
    }

    private let descriptor: Int32

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure.unavailable(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            throw code == EWOULDBLOCK ? Failure.alreadyRunning : Failure.unavailable(code)
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }
}
