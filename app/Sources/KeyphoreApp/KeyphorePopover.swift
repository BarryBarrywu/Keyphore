import AppKit
import SwiftUI
import KeyphoreCore

struct KeyphorePopover: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var state: KeyphoreAppState
    private let foregroundWindowAction: ForegroundWindowAction
    private let checkForUpdates: () -> Void

    init(
        state: KeyphoreAppState,
        foregroundWindowAction: ForegroundWindowAction = .live,
        checkForUpdates: @escaping () -> Void
    ) {
        self.state = state
        self.foregroundWindowAction = foregroundWindowAction
        self.checkForUpdates = checkForUpdates
    }

    private var presentation: KeyboardSignalPresentation {
        KeyboardSignalPresentation(snapshot: state.snapshot, preview: state.previewRecord)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 18)

            if state.menuState == .configurationRequired {
                GuidedSetupView(state: state)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 20)
            } else {
                keyboardSection
            }

            Divider()
            actions
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: state.refresh)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppCopy.value(.productName).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(AppCopy.value(.deviceName))
                    .font(.system(size: 19, weight: .semibold))
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(state.menuState.tint)
                    .frame(width: 7, height: 7)
                Text(AppCopy.value(state.menuState.copyKey))
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(Color.primary.opacity(0.055), in: Capsule())
        }
    }

    private var keyboardSection: some View {
        VStack(spacing: 18) {
            Air65KeyboardView(presentation: presentation)

            signalIndicators

            VStack(spacing: 6) {
                Text(statusTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text(statusDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: presentation.signal)

            if state.migrationRequiresSignalPreview {
                Text(AppCopy.value(.migrationPreviewRequired))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                Button(
                    AppCopy.value(presentation.isPreviewing ? .previewRunningShort : .previewStart),
                    action: state.beginSignalPreview
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.menuState != .ready || presentation.isPreviewing
                          || state.previewRecord?.phase == .awaitingVisualConfirmation)

                previewFeedback

                if state.previewStateFailed {
                    Text(AppCopy.value(.previewStateError))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
    }

    private var signalIndicators: some View {
        HStack(spacing: 3) {
            signalIndicator(.signalOff, title: .signalOffShort)
            signalIndicator(.execution, title: .executionShort)
            signalIndicator(.attention, title: .attentionShort)
            signalIndicator(.completion, title: .completionShort)
        }
        .padding(3)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppCopy.value(presentation.isPreviewing ? .previewTitle : .currentSignal))
        .accessibilityValue(AppCopy.value(presentation.signal.presentation(in: state.snapshot.profile).copyKey))
    }

    private func signalIndicator(_ signal: AggregateSignal, title: AppCopyKey) -> some View {
        let selected = signal == presentation.signal
        return Text(AppCopy.value(title))
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                }
            }
    }

    private var statusTitle: String {
        if state.menuState != .ready {
            return AppCopy.value(state.snapshot.keyboardHealth.copyKey)
        }
        let title = AppCopy.value(presentation.signal.presentation(in: state.snapshot.profile).copyKey)
        return presentation.isPreviewing ? "\(AppCopy.value(.previewTitle)) · \(title)" : title
    }

    private var statusDetail: String {
        if state.menuState != .ready {
            return AppCopy.value(.previewUnavailable)
        }
        guard let appearance = presentation.appearance else {
            return AppCopy.value(presentation.isPreviewing ? .previewRunningShort : .signalOffDescription)
        }
        var details = [
            AppCopy.value(appearance.pattern == .steady ? .settingsSteady : .settingsSlowFlashing),
            "\(appearance.brightness.percent)% \(AppCopy.value(.settingsBrightness))",
        ]
        if !appearance.isVisible {
            details.insert(AppCopy.value(.signalHidden), at: 0)
        }
        if presentation.signal == .completion {
            details.append("\(state.snapshot.profile.completionDisplayDuration.seconds) \(AppCopy.value(.settingsSeconds))")
        }
        return details.joined(separator: " · ")
    }

    @ViewBuilder
    private var previewFeedback: some View {
        if let preview = state.previewRecord {
            switch preview.phase {
            case .pending, .presenting:
                ProgressView(AppCopy.value(.previewRunning))
                    .controlSize(.small)
                    .font(.caption)
            case .awaitingVisualConfirmation:
                VStack(alignment: .leading, spacing: 8) {
                    if preview.protocolReadbackSucceeded {
                        Label(AppCopy.value(.previewProtocolVerified), systemImage: "checkmark.circle")
                    }
                    if preview.rhythmLightPreserved {
                        Label(AppCopy.value(.previewRhythmPreserved), systemImage: "checkmark.circle")
                    }
                    Text(AppCopy.value(.previewConfirmPrompt))
                        .fontWeight(.medium)
                    HStack {
                        Button(AppCopy.value(.previewConfirm)) { state.confirmSignalPreview(.confirmed) }
                        Button(AppCopy.value(.previewReject)) { state.confirmSignalPreview(.rejected) }
                    }
                }
                .font(.caption)
            case .confirmed:
                Text(AppCopy.value(.previewConfirmed)).font(.caption).foregroundStyle(.secondary)
            case .rejected:
                Text(AppCopy.value(.previewRejected)).font(.caption).foregroundStyle(.secondary)
            case .failed:
                Text(AppCopy.value(.previewFailed)).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            HStack {
                if state.menuState != .configurationRequired {
                    settingsButton
                }
                Spacer()
                Button(AppCopy.value(.diagnostics)) {
                    foregroundWindowAction.open { openWindow(id: "diagnostics") }
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 12, weight: .medium))
            .frame(height: 46)

            HStack {
                Button(AppCopy.value(.checkForUpdates), action: checkForUpdates)
                Spacer()
                Button(AppCopy.value(.quit)) { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.bottom, 14)

            if state.quitFailed {
                Text(AppCopy.value(.quitError))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 14)
            }
        }
        .padding(.horizontal, 22)
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            ForegroundSettingsButton(
                title: AppCopy.value(.settings),
                foregroundWindowAction: foregroundWindowAction
            )
        } else {
            Button(AppCopy.value(.settings)) {
                foregroundWindowAction.open {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
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
