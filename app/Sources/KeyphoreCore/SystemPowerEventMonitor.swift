import AppKit
import Foundation

public final class SystemPowerEventMonitor {
    private final class Handler: @unchecked Sendable {
        let call: (CompanionPowerEvent) -> Void

        init(_ call: @escaping (CompanionPowerEvent) -> Void) {
            self.call = call
        }
    }

    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    public convenience init(handler: @escaping (CompanionPowerEvent) -> Void) {
        self.init(
            notificationCenter: NSWorkspace.shared.notificationCenter,
            willSleepNotification: NSWorkspace.willSleepNotification,
            didWakeNotification: NSWorkspace.didWakeNotification,
            handler: handler
        )
    }

    public init(
        notificationCenter: NotificationCenter,
        willSleepNotification: Notification.Name,
        didWakeNotification: Notification.Name,
        handler: @escaping (CompanionPowerEvent) -> Void
    ) {
        self.notificationCenter = notificationCenter
        let handler = Handler(handler)
        observers = [
            notificationCenter.addObserver(
                forName: willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in handler.call(.willSleep) },
            notificationCenter.addObserver(
                forName: didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in handler.call(.didWake) },
        ]
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }
}
