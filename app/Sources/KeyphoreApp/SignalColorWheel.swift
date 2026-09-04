import AppKit
import KeyphoreCore
import SwiftUI

enum SignalPalette {
    struct Swatch {
        let name: AppCopyKey
        let color: SignalColor
    }

    static let colors: [Swatch] = [
        Swatch(name: .colorBlue, color: LocalProfile.default.execution.color),
        Swatch(name: .colorOrange, color: LocalProfile.default.attention.color),
        Swatch(name: .colorGreen, color: LocalProfile.default.completion.color),
        Swatch(name: .colorPurple, color: SignalColor(red: 146, green: 84, blue: 222)),
        Swatch(name: .colorPink, color: SignalColor(red: 236, green: 72, blue: 153)),
        Swatch(name: .colorRed, color: SignalColor(red: 239, green: 68, blue: 68)),
        Swatch(name: .colorWhite, color: SignalColor(red: 255, green: 255, blue: 255)),
    ]
}

struct InteractiveColorStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Circle())
            .background(Color.primary.opacity(hovered ? 0.06 : 0), in: Circle())
            .opacity(configuration.isPressed ? 0.65 : 1)
            .onHover { hovered = $0 }
    }
}

struct SignalColorWheel: View {
    @Binding var color: Color
    private var label: String { AppCopy.value(.settingsColorWheel) }
    static let spectrum: [Color] = (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }

    private var components: NSColor { NSColor(color).usingColorSpace(.sRGB) ?? .white }
    // A legacy black color has no hue; allow the wheel to select a visible color again.
    private var wheelBrightness: Double { components.brightnessComponent == 0 ? 1 : components.brightnessComponent }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                Circle().fill(color).frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
            }
            GeometryReader { geometry in
                let radius = geometry.size.width / 2
                let hue = components.hueComponent
                let saturation = components.saturationComponent
                ZStack {
                    Circle().fill(AngularGradient(colors: Self.spectrum, center: .center))
                    Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                                 startRadius: 0, endRadius: radius))
                    Circle().fill(.black.opacity(1 - wheelBrightness))
                    Circle().strokeBorder(.white, lineWidth: 2).frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.7), radius: 1)
                        .position(x: radius + cos(hue * 2 * .pi) * saturation * radius,
                                  y: radius + sin(hue * 2 * .pi) * saturation * radius)
                }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let dx = value.location.x - radius
                    let dy = value.location.y - radius
                    let hue = (atan2(dy, dx) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
                    color = Color(hue: hue, saturation: min(hypot(dx, dy) / radius, 1), brightness: wheelBrightness)
                })
            }.frame(width: 184, height: 184)
                .focusable()
                .onMoveCommand { direction in
                    switch direction {
                    case .left: adjust(hue: -0.025)
                    case .right: adjust(hue: 0.025)
                    case .up: adjust(saturation: 0.05)
                    case .down: adjust(saturation: -0.05)
                    @unknown default: break
                    }
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(label)
                .accessibilityValue("\(AppCopy.value(.colorHue)) \(Int(components.hueComponent * 360))°, \(AppCopy.value(.colorSaturation)) \(Int(components.saturationComponent * 100))%")
                .accessibilityAdjustableAction { direction in
                    adjust(hue: direction == .increment ? 0.025 : -0.025)
                }
                .accessibilityAction(named: Text(AppCopy.value(.colorIncreaseSaturation))) { adjust(saturation: 0.05) }
                .accessibilityAction(named: Text(AppCopy.value(.colorDecreaseSaturation))) { adjust(saturation: -0.05) }
        }.frame(width: 184)
    }

    private func adjust(hue: Double = 0, saturation: Double = 0) {
        color = Color(hue: (components.hueComponent + hue + 1).truncatingRemainder(dividingBy: 1),
                      saturation: min(max(components.saturationComponent + saturation, 0), 1),
                      brightness: wheelBrightness)
    }
}
