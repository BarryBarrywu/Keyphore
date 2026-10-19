import AppKit
import KeyphoreCore
import SwiftUI

enum SignalPalette {
    static let colors: [SignalColor] = [
        SignalColor(red: 0xFF, green: 0x6D, blue: 0x1E),
        SignalColor(red: 0xFF, green: 0xF2, blue: 0x00),
        SignalColor(red: 0x00, green: 0xFF, blue: 0xAE),
        SignalColor(red: 0x00, green: 0x95, blue: 0xFF),
        SignalColor(red: 0x87, green: 0x87, blue: 0xF8),
        SignalColor(red: 0xFF, green: 0x3B, blue: 0x96),
        SignalColor(red: 0xFC, green: 0x16, blue: 0x16),
        SignalColor(red: 0xFF, green: 0xBF, blue: 0x00),
        SignalColor(red: 0x0F, green: 0xE8, blue: 0xFB),
        SignalColor(red: 0x22, green: 0xFF, blue: 0x22),
        SignalColor(red: 0x22, green: 0x22, blue: 0xFF),
        SignalColor(red: 0xFF, green: 0x4B, blue: 0xFF),
    ]
}

enum SignalColorTextFormat: String, CaseIterable, Hashable {
    case hex = "HEX"
    case rgb = "RGB"
}

enum SignalColorTextCodec {
    static func parse(_ value: String, format: SignalColorTextFormat) -> SignalColor? {
        switch format {
        case .hex:
            var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if hex.hasPrefix("#") { hex.removeFirst() }
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let raw = UInt32(hex, radix: 16) else { return nil }
            return SignalColor(red: UInt8((raw >> 16) & 0xFF),
                               green: UInt8((raw >> 8) & 0xFF),
                               blue: UInt8(raw & 0xFF))
        case .rgb:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("rgb("), trimmed.hasSuffix(")") else { return nil }
            let channels = trimmed.dropFirst(4).dropLast().split(separator: ",")
            guard channels.count == 3 else { return nil }
            let values = channels.compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 3 else { return nil }
            return SignalColor(red: values[0], green: values[1], blue: values[2])
        }
    }

    static func format(_ color: SignalColor, as format: SignalColorTextFormat) -> String {
        switch format {
        case .hex: String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
        case .rgb: "rgb(\(color.red), \(color.green), \(color.blue))"
        }
    }
}

enum RecentSignalColors {
    static let key = "lighting.recent-colors"

    static func load(from defaults: UserDefaults = .standard) -> [SignalColor] {
        (defaults.stringArray(forKey: key) ?? []).compactMap {
            SignalColorTextCodec.parse($0, format: .hex)
        }
    }

    static func record(_ color: SignalColor, in defaults: UserDefaults = .standard) -> [SignalColor] {
        let colors = [color] + load(from: defaults).filter { $0 != color }
        let limited = Array(colors.prefix(12))
        defaults.set(limited.map { SignalColorTextCodec.format($0, as: .hex) }, forKey: key)
        return limited
    }
}

struct SignalColorPickerState {
    private(set) var hue: CGFloat = 0
    private(set) var saturation: CGFloat = 0
    private(set) var brightness: CGFloat = 0

    init(_ color: SignalColor) {
        synchronize(with: color)
    }

    var color: SignalColor {
        let color = NSColor(deviceHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            .usingColorSpace(.sRGB) ?? .black
        return SignalColor(red: UInt8((min(max(color.redComponent, 0), 1) * 255).rounded()),
                           green: UInt8((min(max(color.greenComponent, 0), 1) * 255).rounded()),
                           blue: UInt8((min(max(color.blueComponent, 0), 1) * 255).rounded()))
    }

    mutating func synchronize(with color: SignalColor) {
        guard color != self.color else { return }
        let components = NSColor(srgbRed: CGFloat(color.red) / 255,
                                 green: CGFloat(color.green) / 255,
                                 blue: CGFloat(color.blue) / 255,
                                 alpha: 1)
        brightness = components.brightnessComponent
        if brightness > 0 { saturation = components.saturationComponent }
        if components.saturationComponent > 0 { hue = components.hueComponent }
    }

    @discardableResult
    mutating func update(hue: CGFloat? = nil, saturation: CGFloat? = nil,
                         brightness: CGFloat? = nil) -> SignalColor {
        if let hue { self.hue = Self.clamp(hue) }
        if let saturation { self.saturation = Self.clamp(saturation) }
        if let brightness { self.brightness = Self.clamp(brightness) }
        return color
    }

    private static func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
}

struct SignalColorWheel: View {
    @Binding var color: SignalColor
    @State private var format: SignalColorTextFormat = .hex
    @State private var input = ""
    @State private var recentColors = RecentSignalColors.load()
    @State private var pickerState: SignalColorPickerState

    private let pickerWidth: CGFloat = 250
    private let swatchesWidth: CGFloat = 168
    private let handleSize: CGFloat = 20

    init(color: Binding<SignalColor>) {
        _color = color
        _pickerState = State(initialValue: SignalColorPickerState(color.wrappedValue))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 10) {
                saturationBrightness.frame(width: pickerWidth, height: 226)
                hueBar.frame(width: pickerWidth, height: handleSize)
                inputRow.frame(width: pickerWidth, height: 36)
            }
            VStack(spacing: 12) {
                colorGroup(title: .settingsColorPresets, colors: SignalPalette.colors)
                colorGroup(title: .settingsRecentColors, colors: recentColors)
            }
            .frame(width: swatchesWidth)
        }
        .onAppear {
            pickerState.synchronize(with: color)
            input = SignalColorTextCodec.format(color, as: format)
        }
        .onChange(of: format) { _ in input = SignalColorTextCodec.format(color, as: format) }
        .onChange(of: color) { value in
            input = SignalColorTextCodec.format(value, as: format)
            pickerState.synchronize(with: value)
        }
    }

    private var saturationBrightness: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let x = handleSize / 2 + pickerState.saturation * (size.width - handleSize)
            let y = handleSize / 2 + (1 - pickerState.brightness) * (size.height - handleSize)
            ZStack {
                ZStack {
                    Color(hue: Double(pickerState.hue), saturation: 1, brightness: 1)
                    LinearGradient(colors: [.white, .white.opacity(0)],
                                   startPoint: UnitPoint(x: handleSize / 2 / size.width, y: 0.5),
                                   endPoint: UnitPoint(x: 1 - handleSize / 2 / size.width, y: 0.5))
                    LinearGradient(colors: [.clear, .black],
                                   startPoint: UnitPoint(x: 0.5, y: handleSize / 2 / size.height),
                                   endPoint: UnitPoint(x: 0.5, y: 1 - handleSize / 2 / size.height))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Circle().strokeBorder(.white, lineWidth: 2).frame(width: handleSize, height: handleSize)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                    .position(x: x, y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { updateSaturationBrightness(at: $0.location, in: size) }
                .onEnded { value in
                    updateSaturationBrightness(at: value.location, in: size)
                    commit(pickerState.color)
                })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppCopy.value(.settingsColor))
        .accessibilityValue("\(Int(pickerState.saturation * 100))%, \(Int(pickerState.brightness * 100))%")
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = direction == .increment ? 0.05 : -0.05
            apply(saturation: pickerState.saturation + delta, commit: true)
        }
        .accessibilityAction(named: Text("\(AppCopy.value(.settingsBrightness)) +")) {
            apply(brightness: pickerState.brightness + 0.05, commit: true)
        }
        .accessibilityAction(named: Text("\(AppCopy.value(.settingsBrightness)) −")) {
            apply(brightness: pickerState.brightness - 0.05, commit: true)
        }
    }

    private var hueBar: some View {
        GeometryReader { geometry in
            let centerX = handleSize / 2 + pickerState.hue * (geometry.size.width - handleSize)
            ZStack {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
                    Color(hue: $0, saturation: 1, brightness: 1)
                }, startPoint: UnitPoint(x: handleSize / 2 / geometry.size.width, y: 0.5),
                   endPoint: UnitPoint(x: 1 - handleSize / 2 / geometry.size.width, y: 0.5))
                .frame(height: 12)
                .clipShape(Capsule())
                Circle().strokeBorder(.white, lineWidth: 2).frame(width: handleSize, height: handleSize)
                    .shadow(color: .black.opacity(0.65), radius: 1)
                    .position(x: centerX, y: geometry.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { updateHue(at: $0.location.x, width: geometry.size.width) }
                .onEnded { value in
                    updateHue(at: value.location.x, width: geometry.size.width)
                    commit(pickerState.color)
                })
        }
        .accessibilityLabel(AppCopy.value(.colorHue))
        .accessibilityValue("\(Int(pickerState.hue * 360))°")
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = direction == .increment ? 0.025 : -0.025
            apply(hue: (pickerState.hue + delta + 1).truncatingRemainder(dividingBy: 1),
                  commit: true)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: $format) {
                ForEach(SignalColorTextFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).buttonStyle(.borderless)
            .padding(.horizontal, 8).frame(width: 72, height: 36)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            TextField("", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .onSubmit(commitInput)
                .accessibilityLabel(format.rawValue)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func colorGroup(title: AppCopyKey, colors: [SignalColor]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.value(title)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, choice in
                    Button { choose(choice) } label: {
                        RoundedRectangle(cornerRadius: 8).fill(choice.swiftUIColor)
                            .frame(width: 32, height: 32)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(color == choice ? 0.8 : 0.14),
                                                  lineWidth: color == choice ? 2 : 0.5)
                            }
                            .overlay {
                                if color == choice {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(choice.contrastingForeground)
                                }
                            }
                    }
                    .buttonStyle(NativeColorSwatchStyle())
                    .accessibilityLabel(SignalColorTextCodec.format(choice, as: .hex))
                    .accessibilityAddTraits(color == choice ? .isSelected : [])
                }
            }
            .frame(minHeight: 112, alignment: .top)
        }
        .padding(8)
        .frame(width: swatchesWidth, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func updateSaturationBrightness(at location: CGPoint, in size: CGSize) {
        let usableWidth = max(1, size.width - handleSize)
        let usableHeight = max(1, size.height - handleSize)
        apply(saturation: clamp((location.x - handleSize / 2) / usableWidth),
              brightness: 1 - clamp((location.y - handleSize / 2) / usableHeight))
    }

    private func updateHue(at x: CGFloat, width: CGFloat) {
        let hue = clamp((x - handleSize / 2) / max(1, width - handleSize))
        apply(hue: hue)
    }

    private func apply(hue: CGFloat? = nil, saturation: CGFloat? = nil,
                       brightness: CGFloat? = nil, commit shouldCommit: Bool = false) {
        let value = pickerState.update(hue: hue, saturation: saturation, brightness: brightness)
        color = value
        if shouldCommit { commit(value) }
    }

    private func choose(_ value: SignalColor) {
        pickerState.synchronize(with: value)
        commit(value)
    }

    private func commit(_ value: SignalColor) {
        color = value
        recentColors = RecentSignalColors.record(value)
        input = SignalColorTextCodec.format(value, as: format)
    }

    private func commitInput() {
        guard let parsed = SignalColorTextCodec.parse(input, format: format) else {
            input = SignalColorTextCodec.format(color, as: format)
            return
        }
        choose(parsed)
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
}

private struct NativeColorSwatchStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(hovered ? 0.3 : 0), lineWidth: 1)
                    .padding(-2)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .onHover { hovered = $0 }
    }
}

private extension SignalColor {
    var contrastingForeground: Color {
        let luminance = 0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)
        return luminance > 150 ? .black.opacity(0.72) : .white
    }
}
