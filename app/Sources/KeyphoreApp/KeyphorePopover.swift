import AppKit
import SwiftUI
import KeyphoreCore

struct KeyphorePopover: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var state: KeyphoreAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if state.menuState == .configurationRequired {
                GuidedSetupView(state: state)
            } else {
                Air65KeyboardView(signal: state.snapshot.currentSignal, profile: state.snapshot.profile)
                statusGrid
            }
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

            Text(AppCopy.value(state.menuState.copyKey))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(state.menuState.tint.opacity(0.14))
                .foregroundStyle(state.menuState.tint)
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
            if state.menuState != .configurationRequired {
                Button(AppCopy.value(.settings)) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
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

private struct GuidedSetupView: View {
    @ObservedObject var state: KeyphoreAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppCopy.value(.setupTitle))
                .font(.headline)

            if state.setupSnapshot.phase == .codexHostMissing {
                Label(AppCopy.value(.setupHostMissing), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button(AppCopy.value(.setupRepair), action: state.refresh)
            } else {
                Label(AppCopy.value(.setupHostFound), systemImage: "checkmark.circle")
                Text(hosts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AppCopy.value(.setupHookReview))
                    .font(.subheadline.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.setupSnapshot.hooks, id: \.event.rawValue) { hook in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hook.event.rawValue).font(.system(.caption, design: .monospaced))
                                Text("\(AppCopy.value(.setupFields)): \(fields(hook))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)
                Text(AppCopy.value(.setupPrivacy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.setupFailed {
                    Text(AppCopy.value(.setupError))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button(
                    state.setupIsWorking
                        ? AppCopy.value(.setupWorking)
                        : AppCopy.value(state.setupFailed ? .setupRepair : .setupConsent),
                    action: state.configureAfterReview
                )
                .disabled(state.setupIsWorking)
            }
        }
    }

    private func fields(_ hook: HookDefinition) -> String {
        hook.allowedFields.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private var hosts: String {
        state.setupSnapshot.detectedHosts
            .sorted { $0.rawValue < $1.rawValue }
            .map { host in
                AppCopy.value(host == .desktopApp ? .setupDesktopHost : .setupCommandLineHost)
            }
            .joined(separator: ", ")
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
