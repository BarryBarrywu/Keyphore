import SwiftUI
import KeyphoreCore

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
}
