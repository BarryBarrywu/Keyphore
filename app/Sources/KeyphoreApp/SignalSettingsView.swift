import SwiftUI
import KeyphoreCore

struct SignalSettingsView: View {
    let profile: LocalProfile

    var body: some View {
        Form {
            SignalSettingRow(
                title: AppCopy.value(.execution),
                appearance: profile.execution
            )
            SignalSettingRow(
                title: AppCopy.value(.attention),
                appearance: profile.attention
            )
            SignalSettingRow(
                title: AppCopy.value(.completion),
                appearance: profile.completion
            )
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 280)
        .navigationTitle(AppCopy.value(.settings))
    }
}

private struct SignalSettingRow: View {
    let title: String
    let appearance: SignalAppearance

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Circle()
                    .fill(appearance.color.swiftUIColor)
                    .frame(width: 12, height: 12)
                Text("\(appearance.brightness.percent)%")
                    .monospacedDigit()
            }
        }
    }
}
