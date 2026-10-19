import SwiftUI
import KeyphoreCore

struct KeyboardSignalPresentation {
    let signal: AggregateSignal
    let appearance: SignalAppearance?
    let isControlAvailable: Bool
    let isLit: Bool
    let isPreviewing: Bool
    let controlledZones: ControlledZones

    init(snapshot: LifecycleSnapshot, preview: SignalPreviewRecord?) {
        isPreviewing = preview?.phase == .pending || preview?.phase == .presenting
        if isPreviewing {
            switch preview?.currentPreset {
            case .execution: signal = .execution
            case .attention: signal = .attention
            case .completion: signal = .completion
            case .idle, nil: signal = .signalOff
            }
        } else {
            signal = snapshot.currentSignal
        }
        if isPreviewing, preview?.currentPreset == .idle {
            appearance = snapshot.profile.idle
        } else {
            switch signal {
            case .execution: appearance = snapshot.profile.execution
            case .attention: appearance = snapshot.profile.attention
            case .completion: appearance = snapshot.profile.completion
            case .signalOff: appearance = snapshot.profile.idle
            }
        }
        isControlAvailable = snapshot.menuState == .ready
        controlledZones = snapshot.profile.controlledZones
        isLit = isControlAvailable
            && appearance?.isVisible == true
            && Self.hasLitZone(appearance, controlledZones: controlledZones)
            && (!isPreviewing || preview?.presentationIsLit == true)
    }

    init(signal: AggregateSignal, appearance: SignalAppearance, controlledZones: ControlledZones) {
        self.signal = signal
        self.appearance = appearance
        isControlAvailable = true
        isPreviewing = false
        self.controlledZones = controlledZones
        isLit = appearance.isVisible && Self.hasLitZone(appearance, controlledZones: controlledZones)
    }

    func color(for zone: LightingZone) -> Color {
        appearance?.appearance(for: zone).color.swiftUIColor ?? .clear
    }

    func opacity(for zone: LightingZone) -> Double {
        guard isLit, controlledZones.contains(zone), let appearance else { return 0 }
        let zoneAppearance = appearance.appearance(for: zone)
        guard !zoneAppearance.effect.isOff else { return 0 }
        return Double(zoneAppearance.brightness.percent) / 100
    }

    private static func hasLitZone(
        _ appearance: SignalAppearance?, controlledZones: ControlledZones
    ) -> Bool {
        guard let appearance else { return false }
        return !LightingBehavior.signal(appearance, controlledZones: controlledZones).isOff
    }
}

extension AggregateSignal {
    func presentation(in profile: LocalProfile) -> AggregateSignalPresentation {
        switch self {
        case .signalOff:
            let idleIsLit = !LightingBehavior.signal(profile.idle, controlledZones: profile.controlledZones).isOff
            return AggregateSignalPresentation(
                copyKey: idleIsLit ? .settingsIdle : .signalOff,
                signal: self,
                color: profile.idle.backlight.color.swiftUIColor
            )
        case .execution:
            return AggregateSignalPresentation(
                copyKey: .execution,
                signal: self,
                color: profile.execution.backlight.color.swiftUIColor
            )
        case .attention:
            return AggregateSignalPresentation(
                copyKey: .attention,
                signal: self,
                color: profile.attention.backlight.color.swiftUIColor
            )
        case .completion:
            return AggregateSignalPresentation(
                copyKey: .completion,
                signal: self,
                color: profile.completion.backlight.color.swiftUIColor
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
