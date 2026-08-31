import SwiftUI
import KeyphoreCore

struct Air65KeyboardView: View {
    let signal: AggregateSignal
    let profile: LocalProfile

    private let rows: [[CGFloat]] = [
        Array(repeating: 1, count: 15),
        [1.4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.6],
        [1.65, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.35],
        [2.1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2.05],
        [1.35, 1.15, 1.15, 5.2, 1.15, 1.15, 1.15, 1.35],
    ]

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                VStack(spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        KeyRow(units: row, color: signalColor)
                    }
                }

                VStack(spacing: 5) {
                    Circle()
                        .fill(Color(nsColor: .controlColor))
                        .overlay(Circle().stroke(.white.opacity(0.28)))
                        .frame(width: 20, height: 20)
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(signalColor.opacity(0.8))
                            .frame(width: 20, height: 16)
                    }
                }
            }

            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { _ in
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 15, height: 2)
                }
                Text(AppCopy.value(.rhythmLightUnchanged))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.08))
                )
        )
    }

    private var signalColor: Color {
        signal.presentation(in: profile).color
    }
}

private struct KeyRow: View {
    let units: [CGFloat]
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(units.enumerated()), id: \.offset) { _, unit in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(.white.opacity(0.16))
                    )
                    .frame(width: 14 * unit, height: 14)
            }
        }
    }
}
