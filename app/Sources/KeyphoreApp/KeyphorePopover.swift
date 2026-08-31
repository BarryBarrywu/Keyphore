import AppKit
import SwiftUI
import KeyphoreCore

struct KeyphorePopover: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var state: KeyphoreAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Air65KeyboardView(signal: state.snapshot.currentSignal, profile: state.snapshot.profile)
            statusGrid
            Divider()
            actions
        }
        .padding(20)
        .frame(width: 390)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: state.refresh)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(AppCopy.value(.productName))
                    .font(.title2.weight(.semibold))
                Text(AppCopy.value(.deviceName))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(AppCopy.value(state.snapshot.menuState.copyKey))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(state.snapshot.menuState.tint.opacity(0.14))
                .foregroundStyle(state.snapshot.menuState.tint)
                .clipShape(Capsule())
        }
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text(AppCopy.value(.currentSignal))
                    .foregroundStyle(.secondary)
                Label(
                    AppCopy.value(
                        state.snapshot.currentSignal.presentation(in: state.snapshot.profile).copyKey
                    ),
                    systemImage: state.menuBarSymbol
                )
            }
            GridRow {
                Text(AppCopy.value(.keyboardHealth))
                    .foregroundStyle(.secondary)
                Text(AppCopy.value(state.snapshot.keyboardHealth.copyKey))
            }
        }
        .font(.callout)
    }

    private var actions: some View {
        HStack {
            Button(AppCopy.value(.settings)) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button(AppCopy.value(.diagnostics)) {
                openWindow(id: "diagnostics")
            }
            Spacer()
            Button(AppCopy.value(.quit)) {
                state.prepareToQuit()
                NSApp.terminate(nil)
            }
        }
        .controlSize(.small)
    }
}

private extension MenuState {
    var tint: Color {
        switch self {
        case .configurationRequired: .orange
        case .configured: .blue
        case .ready: .green
        }
    }
}
