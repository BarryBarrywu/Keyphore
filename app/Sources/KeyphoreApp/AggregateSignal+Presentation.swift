import SwiftUI
import KeyphoreCore

struct KeyboardSignalPresentation {
    let signal: AggregateSignal
    let appearance: SignalAppearance?
    let isLit: Bool
    let isPreviewing: Bool

    init(snapshot: LifecycleSnapshot, preview: SignalPreviewRecord?) {
        isPreviewing = preview?.phase == .pending || preview?.phase == .presenting
        if isPreviewing {
            switch preview?.currentSignal {
            case .execution: signal = .execution
            case .attention: signal = .attention
            case .completion: signal = .completion
            case nil: signal = .signalOff
            }
        } else {
            signal = snapshot.currentSignal
        }
        switch signal {
        case .execution: appearance = snapshot.profile.execution
        case .attention: appearance = snapshot.profile.attention
        case .completion: appearance = snapshot.profile.completion
        case .signalOff: appearance = nil
        }
        isLit = snapshot.menuState == .ready
            && appearance?.isVisible == true
            && (!isPreviewing || preview?.presentationIsLit == true)
    }

    var color: Color { appearance?.color.swiftUIColor ?? .clear }
}

extension AggregateSignal {
    func presentation(in profile: LocalProfile) -> AggregateSignalPresentation {
        switch self {
        case .signalOff:
            AggregateSignalPresentation(
                copyKey: .signalOff,
                systemImage: "keyboard",
                color: Color.secondary.opacity(0.16)
            )
        case .execution:
            AggregateSignalPresentation(
                copyKey: .execution,
                systemImage: "play.fill",
                color: profile.execution.color.swiftUIColor
            )
        case .attention:
            AggregateSignalPresentation(
                copyKey: .attention,
                systemImage: "exclamationmark",
                color: profile.attention.color.swiftUIColor
            )
        case .completion:
            AggregateSignalPresentation(
                copyKey: .completion,
                systemImage: "checkmark",
                color: profile.completion.color.swiftUIColor
            )
        }
    }
}

struct AggregateSignalPresentation {
    let copyKey: AppCopyKey
    let systemImage: String
    let color: Color

    var menuBarImage: NSImage {
        let image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: AppCopy.value(copyKey)
        )!
        image.isTemplate = true
        return image
    }
}
