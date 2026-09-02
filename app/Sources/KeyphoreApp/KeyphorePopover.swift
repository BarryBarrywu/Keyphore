import AppKit
import SwiftUI
import KeyphoreCore

struct KeyphorePopover: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var state: KeyphoreAppState
    private let foregroundWindowAction: ForegroundWindowAction

    init(
        state: KeyphoreAppState,
        foregroundWindowAction: ForegroundWindowAction = .live
    ) {
        self.state = state
        self.foregroundWindowAction = foregroundWindowAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if state.menuState == .configurationRequired {
                GuidedSetupView(state: state)
            } else {
                if state.setupSnapshot.phase == .configured {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(AppCopy.value(.setupConfigured), systemImage: "checkmark.circle")
                        Text(AppCopy.value(.setupWaitingForKeyboard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if state.migrationRequiresSignalPreview {
                    migrationPreviewReminder
                }
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
                .foregroundStyle(state.currentSignalPresentation.color)
            }
            GridRow {
                Text(AppCopy.value(.keyboardHealth))
                    .foregroundStyle(.secondary)
                Text(AppCopy.value(state.snapshot.keyboardHealth.copyKey))
            }
        }
        .font(.callout)
    }

    private var migrationPreviewReminder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(AppCopy.value(.migrationPreviewRequired), systemImage: "eye")
                .font(.subheadline.weight(.semibold))
            Text(AppCopy.value(.migrationPreviewDescription))
                .font(.caption)
                .foregroundStyle(.secondary)
            if #available(macOS 14.0, *) {
                ForegroundSettingsButton(
                    title: AppCopy.value(.migrationPreviewAction),
                    foregroundWindowAction: foregroundWindowAction
                )
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if state.menuState != .configurationRequired {
                    if #available(macOS 14.0, *) {
                        ForegroundSettingsButton(
                            title: AppCopy.value(.settings),
                            foregroundWindowAction: foregroundWindowAction
                        )
                    } else {
                        Button(AppCopy.value(.settings)) {
                            foregroundWindowAction.open {
                                NSApp.sendAction(
                                    Selector(("showSettingsWindow:")),
                                    to: nil,
                                    from: nil
                                )
                            }
                        }
                    }
                }
                Button(AppCopy.value(.diagnostics)) {
                    foregroundWindowAction.open {
                        openWindow(id: "diagnostics")
                    }
                }
                Spacer()
                Button(AppCopy.value(.quit)) {
                    NSApp.terminate(nil)
                }
            }
            .controlSize(.small)
            if state.quitFailed {
                Text(AppCopy.value(.quitError))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

@available(macOS 14.0, *)
private struct ForegroundSettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    let title: String
    let foregroundWindowAction: ForegroundWindowAction

    var body: some View {
        Button(title) {
            foregroundWindowAction.open {
                openSettings()
            }
        }
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
            } else if state.setupSnapshot.phase == .legacyMigrationReview
                        || state.setupSnapshot.phase == .legacyMigrationRepair {
                legacyMigration
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
                                Text("\(AppCopy.value(.setupCommand)): \(hook.command)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                Text("\(AppCopy.value(.setupTimeout)): \(hook.timeoutSeconds)s")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(AppCopy.value(.setupHash)): \(hook.reviewedHash)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)
                Text(AppCopy.value(.setupPrivacy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(AppCopy.value(.setupLoginLaunch), isOn: $state.loginLaunchEnabled)
                if state.setupFailed {
                    Text(AppCopy.value(state.setupHooksChanged ? .setupHooksChanged : .setupError))
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

    private var legacyMigration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                AppCopy.value(
                    state.setupSnapshot.phase == .legacyMigrationRepair
                        ? .migrationRepairTitle : .migrationTitle
                ),
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.headline)
            Text(
                AppCopy.value(
                    state.setupSnapshot.phase == .legacyMigrationRepair
                        ? .migrationRepairDescription : .migrationDescription
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(
                state.setupSnapshot.legacyMigrationStatus.components.sorted {
                    $0.rawValue < $1.rawValue
                },
                id: \.rawValue
            ) { component in
                Label(AppCopy.value(component.copyKey), systemImage: "checkmark.circle")
                    .font(.caption)
            }
            Text(AppCopy.value(.migrationFreshConsent))
                .font(.caption)
                .foregroundStyle(.secondary)
            if state.setupFailed {
                Text(AppCopy.value(.migrationError))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button(
                state.setupIsWorking
                    ? AppCopy.value(.setupWorking)
                    : AppCopy.value(
                        state.setupSnapshot.phase == .legacyMigrationRepair
                            ? .migrationRepairAction : .migrationConfirm
                    ),
                action: state.migrateLegacyAfterReview
            )
            .disabled(state.setupIsWorking)
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

private extension LegacyComponent {
    var copyKey: AppCopyKey {
        switch self {
        case .plugin: .migrationComponentPlugin
        case .hooks: .migrationComponentHooks
        case .companionRegistration: .migrationComponentCompanion
        case .managedRuntimeState: .migrationComponentRuntimeState
        }
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
