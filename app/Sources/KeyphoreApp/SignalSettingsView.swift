import AppKit
import KeyphoreCore
import SwiftUI

struct SignalSettingsView: View {
    @ObservedObject var state: KeyphoreAppState

    var body: some View {
        Form {
            signalSection(.execution, appearance: state.snapshot.profile.execution)
            signalSection(.attention, appearance: state.snapshot.profile.attention)
            signalSection(.completion, appearance: state.snapshot.profile.completion)

            Section {
                Stepper(value: completionDuration, in: 1...60) {
                    LabeledContent(AppCopy.value(.settingsCompletionDuration)) {
                        Text("\(state.snapshot.profile.completionDisplayDuration.seconds) \(AppCopy.value(.settingsSeconds))")
                            .monospacedDigit()
                    }
                }
                Toggle(AppCopy.value(.settingsLoginLaunch), isOn: loginLaunch)
            }

            previewSection

            if state.canManageRemoval {
                Section {
                    Button(AppCopy.value(.removalAction), role: .destructive) {
                        state.presentManagedRemoval()
                    }
                }
            }

            if state.settingsFailed {
                Text(AppCopy.value(.settingsSaveError))
                    .foregroundStyle(.red)
            }
            if state.validationFailed {
                Text(AppCopy.value(.settingsValidationError))
                    .foregroundStyle(.red)
            }
            if state.previewStateFailed {
                Text(AppCopy.value(.previewStateError))
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .navigationTitle(AppCopy.value(.settings))
        .onAppear(perform: state.refresh)
        .sheet(isPresented: $state.removalIsPresented) {
            ManagedRemovalView(state: state)
        }
    }

    @ViewBuilder
    private func signalSection(_ signal: CodexSignal, appearance: SignalAppearance) -> some View {
        Section(AppCopy.value(signal.copyKey)) {
            Toggle(
                AppCopy.value(.settingsVisibility),
                isOn: visibilityBinding(appearance, signal: signal)
            )
            ColorPicker(
                AppCopy.value(.settingsColor),
                selection: colorBinding(appearance, signal: signal),
                supportsOpacity: false
            )
            LabeledContent(AppCopy.value(.settingsBrightness)) {
                HStack {
                    Slider(
                        value: brightnessBinding(appearance, signal: signal),
                        in: 1...100,
                        step: 1
                    )
                    Text("\(appearance.brightness.percent)%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .frame(width: 250)
            }
            Picker(
                AppCopy.value(.settingsPattern),
                selection: patternBinding(appearance, signal: signal)
            ) {
                Text(AppCopy.value(.settingsSteady)).tag(SignalPattern.steady)
                Text(AppCopy.value(.settingsSlowFlashing)).tag(SignalPattern.slowFlashing)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section(AppCopy.value(.previewTitle)) {
            if state.migrationRequiresSignalPreview {
                Text(AppCopy.value(.migrationPreviewDescription))
                    .foregroundStyle(.secondary)
            }
            Button(AppCopy.value(.previewStart), action: state.beginSignalPreview)
                .disabled(state.menuState != .ready || previewIsRunning)

            if state.menuState != .ready {
                Text(AppCopy.value(.previewUnavailable))
                    .foregroundStyle(.secondary)
            }

            if let preview = state.previewRecord {
                switch preview.phase {
                case .pending, .presenting:
                    ProgressView(AppCopy.value(.previewRunning))
                case .awaitingVisualConfirmation:
                    if preview.protocolReadbackSucceeded {
                        Label(AppCopy.value(.previewProtocolVerified), systemImage: "checkmark.circle")
                    }
                    if preview.rhythmLightPreserved {
                        Label(AppCopy.value(.previewRhythmPreserved), systemImage: "checkmark.circle")
                    }
                    Text(AppCopy.value(.previewConfirmPrompt))
                    HStack {
                        Button(AppCopy.value(.previewConfirm)) {
                            state.confirmSignalPreview(.confirmed)
                        }
                        Button(AppCopy.value(.previewReject)) {
                            state.confirmSignalPreview(.rejected)
                        }
                    }
                case .confirmed:
                    Label(AppCopy.value(.previewConfirmed), systemImage: "checkmark.circle")
                case .rejected:
                    Label(AppCopy.value(.previewRejected), systemImage: "xmark.circle")
                case .failed:
                    Label(AppCopy.value(.previewFailed), systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    private var previewIsRunning: Bool {
        state.previewRecord?.phase == .pending || state.previewRecord?.phase == .presenting
    }

    private var completionDuration: Binding<Int> {
        Binding(
            get: { Int(state.snapshot.profile.completionDisplayDuration.seconds) },
            set: { value in
                if let duration = CompletionDisplayDuration(seconds: UInt8(value)) {
                    state.updateCompletionDisplayDuration(duration)
                }
            }
        )
    }

    private var loginLaunch: Binding<Bool> {
        Binding(
            get: { state.loginLaunchEnabled },
            set: { state.updateLoginLaunch($0) }
        )
    }

    private func visibilityBinding(
        _ appearance: SignalAppearance,
        signal: CodexSignal
    ) -> Binding<Bool> {
        Binding(
            get: { appearance.isVisible },
            set: { value in
                update(appearance, signal: signal, isVisible: value)
            }
        )
    }

    private func colorBinding(
        _ appearance: SignalAppearance,
        signal: CodexSignal
    ) -> Binding<Color> {
        Binding(
            get: { appearance.color.swiftUIColor },
            set: { color in
                update(appearance, signal: signal, color: SignalColor(swiftUIColor: color))
            }
        )
    }

    private func brightnessBinding(
        _ appearance: SignalAppearance,
        signal: CodexSignal
    ) -> Binding<Double> {
        Binding(
            get: { Double(appearance.brightness.percent) },
            set: { value in
                guard let brightness = SignalBrightness(percent: UInt8(value.rounded())) else { return }
                update(appearance, signal: signal, brightness: brightness)
            }
        )
    }

    private func patternBinding(
        _ appearance: SignalAppearance,
        signal: CodexSignal
    ) -> Binding<SignalPattern> {
        Binding(
            get: { appearance.pattern },
            set: { pattern in
                update(appearance, signal: signal, pattern: pattern)
            }
        )
    }

    private func update(
        _ appearance: SignalAppearance,
        signal: CodexSignal,
        isVisible: Bool? = nil,
        color: SignalColor? = nil,
        brightness: SignalBrightness? = nil,
        pattern: SignalPattern? = nil
    ) {
        state.updateAppearance(
            SignalAppearance(
                isVisible: isVisible ?? appearance.isVisible,
                color: color ?? appearance.color,
                brightness: brightness ?? appearance.brightness,
                pattern: pattern ?? appearance.pattern
            ),
            for: signal
        )
    }
}

private struct ManagedRemovalView: View {
    @ObservedObject var state: KeyphoreAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if state.removalSnapshot.status == .completed {
                Label(AppCopy.value(.removalCompleted), systemImage: "checkmark.circle")
                    .font(.headline)
                Text(AppCopy.value(.removalTrashInstructions))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(AppCopy.value(.removalFinish)) {
                        ManagedRemovalFinishAction.live.perform {
                            state.removalIsPresented = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else if state.removalIsWorking {
                ProgressView(AppCopy.value(.removalWorking))
            } else {
                Text(AppCopy.value(
                    state.removalSnapshot.status == .repairRequired
                        ? .removalRepairTitle : .removalTitle
                ))
                .font(.headline)
                Text(AppCopy.value(
                    state.removalSnapshot.status == .repairRequired
                        ? .removalRepairDescription : .removalDescription
                ))
                .foregroundStyle(.secondary)
                ForEach(
                    state.removalSnapshot.components.sorted { $0.rawValue < $1.rawValue },
                    id: \.rawValue
                ) { component in
                    Label(AppCopy.value(component.copyKey), systemImage: "minus.circle")
                }
                if state.removalFailed {
                    Text(AppCopy.value(.removalFailed))
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button(AppCopy.value(.removalConfirm), role: .destructive) {
                        state.confirmManagedRemoval()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled(state.removalIsWorking || state.removalSnapshot.status == .completed)
    }
}

private extension ManagedRemovalComponent {
    var copyKey: AppCopyKey {
        switch self {
        case .plugin: .removalComponentPlugin
        case .hooks: .removalComponentHooks
        case .companion: .removalComponentCompanion
        case .backgroundRegistration: .removalComponentBackgroundRegistration
        case .localProfile: .removalComponentLocalProfile
        case .managedRuntimeState: .removalComponentManagedRuntimeState
        }
    }
}

private extension SignalColor {
    init(swiftUIColor: Color) {
        let color = NSColor(swiftUIColor).usingColorSpace(.deviceRGB) ?? .black
        func byte(_ component: CGFloat) -> UInt8 {
            UInt8((min(1, max(0, component)) * 255).rounded())
        }
        self.init(
            red: byte(color.redComponent),
            green: byte(color.greenComponent),
            blue: byte(color.blueComponent)
        )
    }
}
