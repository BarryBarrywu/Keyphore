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
                signal: self,
                color: Color.secondary.opacity(0.16)
            )
        case .execution:
            AggregateSignalPresentation(
                copyKey: .execution,
                signal: self,
                color: profile.execution.color.swiftUIColor
            )
        case .attention:
            AggregateSignalPresentation(
                copyKey: .attention,
                signal: self,
                color: profile.attention.color.swiftUIColor
            )
        case .completion:
            AggregateSignalPresentation(
                copyKey: .completion,
                signal: self,
                color: profile.completion.color.swiftUIColor
            )
        }
    }
}

struct AggregateSignalPresentation {
    let copyKey: AppCopyKey
    let signal: AggregateSignal
    let color: Color

    var menuBarAccessibilityLabel: String {
        "\(AppCopy.value(.productName)), \(AppCopy.value(copyKey))"
    }

    var menuBarImage: NSImage {
        let signal = signal
        // The approved B artwork uses an 18-point, top-left-origin coordinate space.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.setLineCap(.round)
            context.setLineJoin(.round)

            context.addPath(CGPath(
                roundedRect: CGRect(x: 1.5, y: 1.5, width: 15, height: 15),
                cornerWidth: 4.2, cornerHeight: 4.2, transform: nil
            ))
            context.setLineWidth(1.35)
            context.strokePath()

            context.move(to: CGPoint(x: 6.5, y: 13.5))
            context.addLine(to: CGPoint(x: 11.5, y: 13.5))
            context.setLineWidth(1.5)
            context.strokePath()

            switch signal {
            case .signalOff:
                break
            case .execution:
                context.move(to: CGPoint(x: 7.15, y: 4.65))
                context.addCurve(
                    to: CGPoint(x: 7.91, y: 4.22),
                    control1: CGPoint(x: 7.15, y: 4.26), control2: CGPoint(x: 7.58, y: 4.02)
                )
                context.addLine(to: CGPoint(x: 11.95, y: 6.7))
                context.addCurve(
                    to: CGPoint(x: 11.95, y: 7.56),
                    control1: CGPoint(x: 12.27, y: 6.9), control2: CGPoint(x: 12.27, y: 7.36)
                )
                context.addLine(to: CGPoint(x: 7.91, y: 10.1))
                context.addCurve(
                    to: CGPoint(x: 7.15, y: 9.67),
                    control1: CGPoint(x: 7.58, y: 10.3), control2: CGPoint(x: 7.15, y: 10.06)
                )
                context.closePath()
                context.fillPath()
            case .attention:
                context.move(to: CGPoint(x: 9, y: 4.75))
                context.addLine(to: CGPoint(x: 9, y: 7.95))
                context.setLineWidth(1.8)
                context.strokePath()
                context.fillEllipse(in: CGRect(x: 8.05, y: 9.1, width: 1.9, height: 1.9))
            case .completion:
                context.move(to: CGPoint(x: 5.7, y: 7.7))
                context.addLine(to: CGPoint(x: 7.9, y: 9.8))
                context.addLine(to: CGPoint(x: 12.3, y: 5.3))
                context.setLineWidth(1.7)
                context.strokePath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = menuBarAccessibilityLabel
        return image
    }
}
