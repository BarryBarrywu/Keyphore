import AppKit
import SwiftUI
import KeyphoreCore

struct KeyphorePopover: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var state: KeyphoreAppState
    private let foregroundWindowAction: ForegroundWindowAction

    init(
        state: KeyphoreAppState,
        foregroundWindowAction: ForegroundWindowAction = .live
    ) {
        self.state = state
        self.foregroundWindowAction = foregroundWindowAction
    }

    private var presentation: KeyboardSignalPresentation {
        KeyboardSignalPresentation(snapshot: state.snapshot, preview: state.previewRecord)
    }

    private var animatesSignal: Bool {
        presentation.isLit && !presentation.isPreviewing
            && presentation.appearance?.pattern == .slowFlashing && !reduceMotion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("KEYPHORE")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(.secondary)
                Spacer()
                settingsButton.buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(.bottom, 16)

            if state.isStarting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(AppCopy.value(.startupProgress))
                }.padding(.vertical, 20)
            } else if state.menuState == .configurationRequired {
                GuidedSetupView(state: state)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(statusTitle).font(.system(size: 25, weight: .semibold)).tracking(-0.6)
                    Text(statusDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 62, alignment: .top)
                .padding(.bottom, 22)

                if !candidateModels.isEmpty {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(candidateModels, id: \.self) { model in
                                if candidateModels.count > 1 {
                                    Text(model.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                                CandidateKeyboardIllustration(model: model)
                            }
                        }
                    }
                    .frame(height: candidateModels.count == 1
                           ? 344 / CandidateKeyboardIllustration(model: candidateModels[0]).aspectRatio : 280)
                    .padding(.bottom, 18)
                } else {
                    TimelineView(.animation(minimumInterval: 0.2, paused: !animatesSignal)) { context in
                        Air65KeyboardView(
                            presentation: presentation,
                            isPatternLit: !animatesSignal || Int(context.date.timeIntervalSince1970) % 2 == 0,
                            layout: state.snapshot.keyboardHealth.model == .air75V3 ? .air75ANSI : .air65
                        )
                    }
                    .frame(width: 344, height: 344 * (state.snapshot.keyboardHealth.model == .air75V3 ? 186 : 160) / 416)
                    .padding(.bottom, 18)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(hasUnverifiedKeyboard ? statusTitle : (state.snapshot.keyboardHealth.model?.rawValue ?? AppCopy.value(.deviceName))).font(.system(size: 12, weight: .medium))
                        HStack(spacing: 5) {
                            Circle().fill(state.menuState == .ready ? Color.green : .secondary)
                                .frame(width: 4, height: 4)
                            Text(AppCopy.value(connectionDetail))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()

                }
            }
            if state.previewStateFailed {
                Text(AppCopy.value(.previewStateError)).font(.caption).foregroundStyle(.red).padding(.top, 12)
            }
            if state.quitFailed {
                Text(AppCopy.value(.quitError)).font(.caption).foregroundStyle(.red).padding(.top, 10)
            }
        }
        .padding(24).frame(width: 392)
        .background(colorScheme == .dark ? Color(white: 0.135) : Color(white: 0.995))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .onAppear(perform: state.refresh)
    }

    private var candidateModels: [CandidateKeyboardModel] {
        if let model = state.snapshot.keyboardHealth.model, model.isExperimental,
           let candidate = CandidateKeyboardModel(rawValue: model.rawValue) { return [candidate] }
        guard case .unverified(let interfaces) = state.snapshot.keyboardHealth else { return [] }
        return Array(Set(interfaces.compactMap(\.model))).sorted { $0.rawValue < $1.rawValue }
    }

    private var hasUnverifiedKeyboard: Bool {
        if case .unverified = state.snapshot.keyboardHealth { return true }
        return false
    }

    private var statusTitle: String {
        if candidateModels.count > 1 { return AppCopy.value(.candidateMultiple) }
        if case .unverified(let interfaces) = state.snapshot.keyboardHealth {
            return Array(Set(interfaces.map { $0.model?.rawValue ?? $0.product })).sorted().joined(separator: ", ")
        }
        if state.menuState != .ready { return AppCopy.value(state.snapshot.keyboardHealth.copyKey) }
        if presentation.isPreviewing { return AppCopy.value(.previewRunningShort) }
        switch presentation.signal {
        case .execution: return AppCopy.value(.statusExecuting)
        case .attention: return AppCopy.value(.statusAttention)
        case .completion: return AppCopy.value(.statusCompleted)
        case .signalOff: return AppCopy.value(.statusNoSignal)
        }
    }

    private var connectionDetail: AppCopyKey {
        switch state.snapshot.keyboardHealth {
        case .connected: .statusUSBConnected
        case .disconnected: .statusWaitingForUSB
        default: state.snapshot.keyboardHealth.copyKey
        }
    }

    private var statusDetail: String {
        if state.snapshot.keyboardHealth.model?.isExperimental == true { return AppCopy.value(.experimentalEnabled) }
        if case .unverified = state.snapshot.keyboardHealth { return AppCopy.value(.keyboardUnverifiedDetail) }
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

    private var settingsButton: some View {
        Button {
            foregroundWindowAction.open { state.openSettings?() }
        } label: {
            Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }.accessibilityLabel(AppCopy.value(.settings)).help(AppCopy.value(.settings))
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
                Button(AppCopy.value(state.previewRecord == nil ? .deviceCheckStart : .deviceCheckRetry), action: state.beginSignalPreview)
                    .disabled(state.menuState != .ready || state.previewRecord?.phase == .pending
                              || state.previewRecord?.phase == .presenting
                              || state.previewRecord?.phase == .awaitingVisualConfirmation)
            }
            if let preview = state.previewRecord {
                Text(AppCopy.value(.deviceCheckRecent)).font(.caption).foregroundStyle(.secondary)
                switch preview.phase {
                case .pending, .presenting:
                    Text(AppCopy.value(.previewRunning)).foregroundStyle(.secondary)
                case .awaitingVisualConfirmation:
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
