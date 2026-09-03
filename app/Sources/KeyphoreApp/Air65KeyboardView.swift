import SwiftUI
import KeyphoreCore

struct Air65KeyboardView: View {
    let presentation: KeyboardSignalPresentation

    private struct Key {
        enum Surface { case standard, mint, yellow, knob }
        let label: String
        let units: CGFloat
        let surface: Surface

        init(_ label: String, _ units: CGFloat = 1, _ surface: Surface = .standard) {
            self.label = label
            self.units = units
            self.surface = surface
        }
    }

    private let rows: [[Key]] = [
        [
            Key("", 1, .mint), Key("!\n1"), Key("@\n2"), Key("#\n3"), Key("$\n4"),
            Key("%\n5"), Key("^\n6"), Key("&\n7"), Key("*\n8"), Key("(\n9"),
            Key(")\n0"), Key("_\n−"), Key("+\n="), Key("BACKSPACE", 2), Key("", 1, .knob),
        ],
        [
            Key("TAB", 1.5), Key("Q"), Key("W"), Key("E"), Key("R"), Key("T"),
            Key("Y"), Key("U"), Key("I"), Key("O"), Key("P"), Key("{\n["),
            Key("}\n]"), Key("|\n\u{005C}", 1.5), Key("", 1, .yellow),
        ],
        [
            Key("CAPS", 1.75), Key("A"), Key("S"), Key("D"), Key("F"), Key("G"),
            Key("H"), Key("J"), Key("K"), Key("L"), Key(":\n;"), Key("\u{0022}\n'"),
            Key("ENTER", 2.25), Key("HOME"),
        ],
        [
            Key("SHIFT", 2.25), Key("Z"), Key("X"), Key("C"), Key("V"), Key("B"),
            Key("N"), Key("M"), Key("<\n,"), Key(">\n."), Key("?\n/"),
            Key("SHIFT", 1.75), Key("↑"), Key("END"),
        ],
        [
            Key("CTRL", 1.25), Key("OPT", 1.25), Key("CMD", 1.25), Key("", 6.25),
            Key("CMD"), Key("FN"), Key("CTRL"), Key("←"), Key("↓"), Key("→"),
        ],
    ]

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 416
            let gap = 3 * scale
            let pitch = (geometry.size.width - 32 * scale + gap) / 16
            let keyHeight = (geometry.size.height - 26 * scale - gap * 4) / 5

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.white, Color(red: 0.78, green: 0.79, blue: 0.81)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .shadow(color: .black.opacity(0.16), radius: 8 * scale, y: 5 * scale)

                RoundedRectangle(cornerRadius: 11 * scale, style: .continuous)
                    .fill(Color(red: 0.12, green: 0.13, blue: 0.14))
                    .padding(.horizontal, 13 * scale)
                    .padding(.vertical, 10 * scale)

                RoundedRectangle(cornerRadius: 15 * scale, style: .continuous)
                    .strokeBorder(.white.opacity(0.85), lineWidth: scale)
                    .padding(3 * scale)

                VStack(spacing: gap) {
                    ForEach(rows.indices, id: \.self) { index in
                        HStack(spacing: gap) {
                            ForEach(rows[index].indices, id: \.self) { column in
                                let key = rows[index][column]
                                keycap(key, scale: scale)
                                    .frame(width: pitch * key.units - gap, height: keyHeight)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16 * scale)
                .padding(.vertical, 13 * scale)

                HStack {
                    rhythmLight(scale: scale, height: keyHeight)
                    Spacer()
                    rhythmLight(scale: scale, height: keyHeight)
                }
                .padding(.horizontal, 5 * scale)
                .padding(.top, 13 * scale)
            }
        }
        .aspectRatio(416 / 160, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppCopy.value(.keyboardIllustration))
        .accessibilityValue(AppCopy.value(presentation.signal.presentation(in: .default).copyKey))
        .accessibilityHint(AppCopy.value(.rhythmLightUnchanged))
        .help(AppCopy.value(.rhythmLightUnchanged))
    }

    @ViewBuilder
    private func keycap(_ key: Key, scale: CGFloat) -> some View {
        if key.surface == .knob {
            ZStack {
                Circle().fill(Color(red: 0.86, green: 0.24, blue: 0.17))
                Circle().strokeBorder(.white.opacity(0.55), lineWidth: scale)
                Capsule()
                    .fill(Color(red: 0.52, green: 0.13, blue: 0.10))
                    .frame(width: 2.5 * scale, height: 12 * scale)
                    .rotationEffect(.degrees(40))
            }
            .padding(2 * scale)
        } else {
            RoundedRectangle(cornerRadius: 5 * scale, style: .continuous)
                .fill(surfaceColor(key))
                .overlay {
                    RoundedRectangle(cornerRadius: 5 * scale, style: .continuous)
                        .fill(presentation.color.opacity(key.surface == .standard ? lightOpacity * 0.14 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5 * scale, style: .continuous)
                        .strokeBorder(.white.opacity(0.8), lineWidth: 0.6 * scale)
                }
                .overlay {
                    Text(key.label)
                        .font(.system(size: (key.label.count > 4 ? 4.4 : 6.7) * scale,
                                      weight: .medium, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, scale)
                }
                .overlay {
                    if key.surface == .mint || key.surface == .yellow {
                        Circle().fill(.black.opacity(0.08)).frame(width: 11 * scale, height: 11 * scale)
                    }
                }
                .shadow(color: presentation.color.opacity(lightOpacity * 0.5), radius: 3 * scale, y: scale)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(presentation.color.opacity(lightOpacity * 0.65))
                        .frame(height: 2 * scale)
                        .padding(.horizontal, 3 * scale)
                        .padding(.bottom, 2 * scale)
                }
        }
    }

    private var lightOpacity: Double {
        presentation.isLit ? Double(presentation.appearance?.brightness.percent ?? 0) / 100 : 0
    }

    private func surfaceColor(_ key: Key) -> Color {
        switch key.surface {
        case .standard: Color(red: 0.94, green: 0.94, blue: 0.95)
        case .mint: Color(red: 0.40, green: 0.82, blue: 0.66)
        case .yellow: Color(red: 0.95, green: 0.77, blue: 0.16)
        case .knob: .clear
        }
    }

    private func rhythmLight(scale: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(Color(red: 0.43, green: 0.94, blue: 1).opacity(0.78))
            .frame(width: 2.5 * scale, height: height)
            .shadow(color: .cyan.opacity(0.4), radius: 2 * scale)
    }
}
