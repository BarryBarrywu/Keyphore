import SwiftUI
import KeyphoreCore

struct Air65KeyboardView: View {
    let presentation: KeyboardSignalPresentation
    var isPatternLit = true
    var layout: Layout = .air65

    enum Layout {
        case air65, air75ANSI, kick75ANSI

        var height: CGFloat { self == .air65 ? 160 : 186 }
        var units: CGFloat { self == .kick75ANSI ? 16.25 : 16 }
        var illustrationKey: AppCopyKey {
            switch self {
            case .air65: .keyboardIllustration
            case .air75ANSI: .air75KeyboardIllustration
            case .kick75ANSI: .kick75KeyboardIllustration
            }
        }
    }
    @Environment(\.colorScheme) private var colorScheme

    private struct Key {
        enum Surface { case standard, mint, yellow, knob, spacer }
        let label: String
        let units: CGFloat
        let surface: Surface

        init(_ label: String, _ units: CGFloat = 1, _ surface: Surface = .standard) {
            self.label = label
            self.units = units
            self.surface = surface
        }
    }

    private let air65Rows: [[Key]] = [
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

    private var rows: [[Key]] {
        if layout == .kick75ANSI { return kick75Rows }
        guard layout == .air75ANSI else { return air65Rows }
        let functionRow = [Key("", 1, .mint)]
            + (1...12).map { Key("F\($0)") }
            + [Key("♫"), Key("", 1, .yellow), Key("", 1, .knob)]
        var mainRows = air65Rows
        mainRows[0][0] = Key("~\n`")
        mainRows[0][mainRows[0].count - 1] = Key("PGUP")
        mainRows[1][mainRows[1].count - 1] = Key("PGDN")
        return [functionRow] + mainRows
    }

    private var kick75Rows: [[Key]] {
        let separator = Key("", 0.25, .spacer)
        var functionRow = [Key("ESC", 1, .mint), separator]
        for group in 0..<3 {
            functionRow += (1...4).map { Key("F\(group * 4 + $0)") }
            functionRow.append(separator)
        }
        functionRow += [Key("DEL", 1, .yellow), separator, Key("", 1, .knob)]
        var mainRows = air65Rows
        mainRows[0][0] = Key("~\n`")
        for (index, label) in ["HOME", "PGUP", "PGDN"].enumerated() {
            mainRows[index].removeLast()
            mainRows[index] += [separator, Key(label)]
        }
        mainRows[3].removeLast()
        mainRows[3] += [separator, Key("", 1, .spacer)]
        mainRows[4] = [
            Key("CTRL", 1.25), Key("OPT", 1.25), Key("CMD", 1.25), Key("", 6.25),
            Key("CMD", 1.25), Key("FN", 1.25), Key("", 0.5, .spacer),
            Key("←"), Key("↓"), separator, Key("→"),
        ]
        return [functionRow] + mainRows
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 416
            let gap = 3 * scale
            let pitch = (geometry.size.width - 32 * scale + gap) / layout.units
            let keyHeight = (geometry.size.height - 26 * scale - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(white: colorScheme == .dark ? 0.84 : 0.97), Color(red: 0.78, green: 0.79, blue: 0.81)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .shadow(color: .black.opacity(0.12), radius: 5 * scale, y: 3 * scale)

                if layout != .kick75ANSI {
                    RoundedRectangle(cornerRadius: 11 * scale, style: .continuous)
                        .fill(Color(red: 0.12, green: 0.13, blue: 0.14))
                        .padding(.horizontal, 13 * scale)
                        .padding(.vertical, 10 * scale)
                }

                RoundedRectangle(cornerRadius: 15 * scale, style: .continuous)
                    .strokeBorder(.white.opacity(0.65), lineWidth: scale)
                    .padding(3 * scale)

                VStack(spacing: gap) {
                    ForEach(rows.indices, id: \.self) { index in
                        HStack(spacing: gap) {
                            ForEach(rows[index].indices, id: \.self) { column in
                                let key = rows[index][column]
                                keycap(key, scale: scale)
                                    .frame(width: pitch * key.units - gap, height: keyHeight)
                                    .background {
                                        if layout == .kick75ANSI && key.surface != .spacer && key.surface != .knob {
                                            RoundedRectangle(cornerRadius: 5 * scale)
                                                .fill(Color(white: 0.14))
                                                .padding(-scale)
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16 * scale)
                .padding(.vertical, 13 * scale)

                if layout != .kick75ANSI {
                    HStack {
                        rhythmLight(scale: scale, height: keyHeight)
                        Spacer()
                        rhythmLight(scale: scale, height: keyHeight)
                    }
                    .padding(.horizontal, 5 * scale)
                    .padding(.top, 13 * scale)
                }
            }
        }
        .aspectRatio(416 / layout.height, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppCopy.value(layout.illustrationKey))
        .accessibilityValue(AppCopy.value(layout != .air65 ? .keyboardUnverified : presentation.signal.presentation(in: .default).copyKey))
        .accessibilityHint(AppCopy.value(layout != .air65 ? .keyboardUnverifiedDetail : .rhythmLightUnchanged))
        .help(AppCopy.value(layout != .air65 ? .keyboardUnverifiedDetail : .rhythmLightUnchanged))
    }

    @ViewBuilder
    private func keycap(_ key: Key, scale: CGFloat) -> some View {
        if key.surface == .spacer {
            Color.clear
        } else if key.surface == .knob {
            ZStack {
                Circle().fill(Color(red: 0.86, green: 0.24, blue: 0.17))
                Circle().strokeBorder(.white.opacity(0.55), lineWidth: scale)
                if layout == .kick75ANSI {
                    ForEach([45.0, -45.0], id: \.self) { angle in
                        Capsule()
                            .fill(Color(red: 0.52, green: 0.13, blue: 0.10))
                            .frame(width: 3.5 * scale, height: 16 * scale)
                            .rotationEffect(.degrees(angle))
                    }
                } else {
                    Capsule()
                        .fill(Color(red: 0.52, green: 0.13, blue: 0.10))
                        .frame(width: 2.5 * scale, height: 12 * scale)
                        .rotationEffect(.degrees(40))
                }
            }
            .padding(2 * scale)
        } else {
            RoundedRectangle(cornerRadius: 5 * scale, style: .continuous)
                .fill(surfaceColor(key))
                .overlay {
                    RoundedRectangle(cornerRadius: 5 * scale, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.025)],
                                             startPoint: .top, endPoint: .bottom))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5 * scale, style: .continuous)
                        .fill(presentation.color.opacity(key.surface == .standard ? lightOpacity * 0.07 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5 * scale, style: .continuous)
                        .strokeBorder(.white.opacity(0.65), lineWidth: 0.6 * scale)
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
                .shadow(color: presentation.color.opacity(lightOpacity * 0.22), radius: 2 * scale, y: scale)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(presentation.color.opacity(lightOpacity * 0.58))
                        .frame(height: 2 * scale)
                        .padding(.horizontal, 3 * scale)
                        .padding(.bottom, 2 * scale)
                }
        }
    }

    private var lightOpacity: Double {
        layout == .air65 && presentation.isLit && isPatternLit ? Double(presentation.appearance?.brightness.percent ?? 0) / 100 : 0
    }

    private func surfaceColor(_ key: Key) -> Color {
        switch key.surface {
        case .standard: Color(white: colorScheme == .dark ? 0.86 : 0.94)
        case .mint: Color(red: 0.40, green: 0.82, blue: 0.66)
        case .yellow: Color(red: 0.95, green: 0.77, blue: 0.16)
        case .knob, .spacer: .clear
        }
    }

    private func rhythmLight(scale: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(Color(red: 0.43, green: 0.94, blue: 1).opacity(0.78))
            .frame(width: 2.5 * scale, height: height)
            .shadow(color: .cyan.opacity(0.4), radius: 2 * scale)
    }
}

struct CandidateKeyboardIllustration: View {
    let model: CandidateKeyboardModel
    @Environment(\.colorScheme) private var colorScheme

    var aspectRatio: Double {
        switch model {
        case .air75V3, .kick75IO, .kick75HighIO: 416 / 186
        default: model.definition.aspectRatio
        }
    }

    var body: some View {
        Group {
            if model == .air75V3 || model == .kick75IO || model == .kick75HighIO {
                Air65KeyboardView(
                    presentation: KeyboardSignalPresentation(snapshot: LifecycleSnapshot(
                        health: .configured(keyboard: .disconnected), menuState: .configured,
                        durableStatus: .signalOff, currentSignal: .signalOff, profile: .default
                    ), preview: nil),
                    layout: model == .air75V3 ? .air75ANSI : .kick75ANSI
                )
            } else {
                Canvas { context, size in
                    let definition = model.definition
                    let unit = size.width / (definition.width + 1.2)
                    let inset = 0.6 * unit
                    let shell = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: unit * 0.65)
                    context.fill(shell, with: .linearGradient(Gradient(colors: [
                        Color(white: colorScheme == .dark ? 0.84 : 0.97),
                        Color(red: 0.78, green: 0.79, blue: 0.81)
                    ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    context.stroke(shell, with: .color(.white.opacity(0.65)), lineWidth: 0.7)
                    for key in definition.keys {
                        let rect = CGRect(x: inset + key.x * unit, y: inset + key.y * unit,
                                          width: key.width * unit - unit * 0.09,
                                          height: key.height * unit - unit * 0.09)
                        if key.shape == .knob {
                            context.fill(Path(ellipseIn: rect.insetBy(dx: unit * 0.08, dy: unit * 0.08)),
                                         with: .color(Color(red: 0.86, green: 0.24, blue: 0.17)))
                            var indicator = Path()
                            indicator.move(to: CGPoint(x: rect.midX - unit * 0.15, y: rect.midY + unit * 0.15))
                            indicator.addLine(to: CGPoint(x: rect.midX + unit * 0.15, y: rect.midY - unit * 0.15))
                            context.stroke(indicator, with: .color(.black.opacity(0.25)),
                                           style: StrokeStyle(lineWidth: unit * 0.09, lineCap: .round))
                            continue
                        }
                        let shape = keyPath(key, rect: rect, unit: unit)
                        let surface = key.accent ? Color(red: 0.40, green: 0.82, blue: 0.66)
                            : Color(white: colorScheme == .dark ? 0.86 : 0.94)
                        context.fill(shape, with: .color(surface))
                        context.stroke(shape, with: .color(.black.opacity(0.65)), lineWidth: unit * 0.055)
                        let longestLine = key.label.split(separator: "\n").map(\.count).max() ?? 1
                        let fontSize = min(unit * 0.27, (rect.width - unit * 0.12) / (Double(longestLine) * 0.68))
                        let label = Text(key.label)
                            .font(.system(size: fontSize, weight: .medium, design: .rounded))
                            .foregroundColor(.black.opacity(0.7))
                        context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY))
                    }
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.rawValue + " · " + AppCopy.value(.candidateIllustration))
        .accessibilityValue(AppCopy.value(.keyboardUnverified))
    }

    private func keyPath(_ key: CandidateKeyboardKey, rect: CGRect, unit: Double) -> Path {
        guard key.shape == .isoEnter else {
            return Path(roundedRect: rect, cornerRadius: unit * 0.17)
        }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + unit * 0.25, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + unit * 0.25, y: rect.minY + unit))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + unit))
        path.closeSubpath()
        return path
    }
}

struct CandidateKeyboardCatalogView: View {
    @State private var selection: CandidateKeyboardModel = .air75V3

    var body: some View {
        DisclosureGroup(AppCopy.value(.candidateCatalog)) {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppCopy.value(.candidateCatalogDetail))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(AppCopy.value(.candidateModel), selection: $selection) {
                    ForEach(CandidateKeyboardModel.allCases.sorted { $0.rawValue < $1.rawValue }, id: \.self) { model in
                        Text(model.rawValue).tag(model)
                    }
                }
                CandidateKeyboardIllustration(model: selection)
                    .padding(.vertical, 8)
            }.padding(.top, 10)
        }.padding(.vertical, 14)
    }
}
