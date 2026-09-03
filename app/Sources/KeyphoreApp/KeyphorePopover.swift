import AppKit
import SwiftUI
import KeyphoreCore

struct KeyphorePopover: View {
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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("KEYPHORE")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(.secondary)
                Spacer()
                settingsButton.buttonStyle(.borderless).foregroundStyle(.secondary)
            }.padding(.bottom, 16)

            if state.menuState == .configurationRequired {
                GuidedSetupView(state: state)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(statusTitle).font(.system(size: 25, weight: .semibold)).tracking(-0.6)
                    Text(statusDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                .padding(.bottom, 22)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: presentation.signal)

                Air65KeyboardView(presentation: presentation).padding(.bottom, 18)

                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(AppCopy.value(.deviceName)).font(.system(size: 12, weight: .medium))
                        Text(AppCopy.value(state.menuState == .ready ? .statusUSBConnected : state.snapshot.keyboardHealth.copyKey))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: state.beginSignalPreview) {
                        Label(AppCopy.value(presentation.isPreviewing ? .previewRunningShort : .previewStart),
                              systemImage: "play.fill")
                    }
                    .font(.system(size: 11, weight: .medium)).controlSize(.regular)
                    .disabled(state.menuState != .ready || presentation.isPreviewing
                              || state.previewRecord?.phase == .awaitingVisualConfirmation)
                }
                if state.previewRecord != nil || state.migrationRequiresSignalPreview {
                    SignalPreviewFeedback(state: state).padding(.top, 14)
                }
            }
            if state.previewStateFailed {
                Text(AppCopy.value(.previewStateError)).font(.caption).foregroundStyle(.red).padding(.top, 12)
            }
            Divider().padding(.top, 20).padding(.bottom, 12)
            HStack {
                Button(AppCopy.value(.checkForUpdates), action: checkForUpdates)
                Spacer()
                Button(AppCopy.value(.quit)) { NSApp.terminate(nil) }
            }.buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(.secondary)
            if state.quitFailed {
                Text(AppCopy.value(.quitError)).font(.caption).foregroundStyle(.red).padding(.top, 10)
            }
        }
        .padding(24).frame(width: 392)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: state.refresh)
    }

    private var statusTitle: String {
        if state.menuState != .ready { return AppCopy.value(state.snapshot.keyboardHealth.copyKey) }
        if presentation.isPreviewing { return AppCopy.value(.previewRunningShort) }
        switch presentation.signal {
        case .execution: return AppCopy.value(.statusExecuting)
        case .attention: return AppCopy.value(.statusAttention)
        case .completion: return AppCopy.value(.statusCompleted)
        case .signalOff: return AppCopy.value(.statusNoSignal)
        }
    }

    private var statusDetail: String {
        if state.menuState != .ready { return AppCopy.value(.previewUnavailable) }
        if presentation.isPreviewing {
            return AppCopy.value(presentation.signal.presentation(in: state.snapshot.profile).copyKey)
        }
        switch presentation.signal {
        case .execution: return AppCopy.value(.statusExecutionDetail)
        case .attention: return AppCopy.value(.statusAttentionDetail)
        case .completion: return AppCopy.value(.statusCompletionDetail)
        case .signalOff: return AppCopy.value(.signalOffDescription)
        }
    }

    @ViewBuilder private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            ForegroundSettingsButton(title: AppCopy.value(.settings), foregroundWindowAction: foregroundWindowAction)
        } else {
            Button {
                foregroundWindowAction.open {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            } label: {
                Image(systemName: "gearshape").frame(width: 28, height: 28)
            }.accessibilityLabel(AppCopy.value(.settings)).help(AppCopy.value(.settings))
        }
    }
}

struct SignalPreviewFeedback: View {
    @ObservedObject var state: KeyphoreAppState
    var allowsRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.migrationRequiresSignalPreview {
                Text(AppCopy.value(.migrationPreviewDescription)).foregroundStyle(.secondary)
            }
            if allowsRestart {
                Button(AppCopy.value(.previewStart), action: state.beginSignalPreview)
                    .disabled(state.menuState != .ready || state.previewRecord?.phase == .pending
                              || state.previewRecord?.phase == .presenting
                              || state.previewRecord?.phase == .awaitingVisualConfirmation)
            }
            if let preview = state.previewRecord {
                switch preview.phase {
                case .pending, .presenting:
                    Text(AppCopy.value(.previewRunning)).foregroundStyle(.secondary)
                case .awaitingVisualConfirmation:
                    if preview.protocolReadbackSucceeded { Text(AppCopy.value(.previewProtocolVerified)) }
                    if preview.rhythmLightPreserved { Text(AppCopy.value(.previewRhythmPreserved)) }
                    Text(AppCopy.value(.previewConfirmPrompt)).fontWeight(.medium)
                    HStack {
                        Button(AppCopy.value(.previewConfirm)) { state.confirmSignalPreview(.confirmed) }
                        Button(AppCopy.value(.previewReject)) { state.confirmSignalPreview(.rejected) }
                    }
                case .confirmed: Text(AppCopy.value(.previewConfirmed)).foregroundStyle(.secondary)
                case .rejected: Text(AppCopy.value(.previewRejected)).foregroundStyle(.secondary)
                case .failed: Text(AppCopy.value(.previewFailed)).foregroundStyle(.red)
                }
            }
        }.font(.system(size: 12))
    }
}

@available(macOS 14.0, *)
private struct ForegroundSettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    let title: String
    let foregroundWindowAction: ForegroundWindowAction

    var body: some View {
        Button {
            foregroundWindowAction.open { openSettings() }
        } label: {
            Image(systemName: "gearshape").frame(width: 28, height: 28)
        }
        .accessibilityLabel(title).help(title)
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
