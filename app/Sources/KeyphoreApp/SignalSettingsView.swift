import AppKit
import KeyphoreCore
import SwiftUI

struct SignalSettingsView: View {
    @ObservedObject var state: KeyphoreAppState
    let checkForUpdates: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var editingSignal: CodexSignal = .execution
    @State private var showDiagnostics = false
    @State private var showColorWheel = false

    private var appearance: SignalAppearance { state.snapshot.profile.appearance(for: editingSignal) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppCopy.value(.settings)).font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section(.settingsDevice) { device }
                    section(.settingsSignals) { signals }
                    section(.settingsGeneral) { general }
                    if state.canManageRemoval {
                        Button(AppCopy.value(.removalAction), role: .destructive) { state.presentManagedRemoval() }
                            .buttonStyle(.borderless)
                    }
                    errors
                }.padding(.horizontal, 28).padding(.bottom, 24)
            }
            HStack {
                Button(AppCopy.value(.checkForUpdates), action: checkForUpdates)
                Spacer()
                Button(AppCopy.value(.quit)) { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 28).padding(.vertical, 16)
            if state.quitFailed {
                Text(AppCopy.value(.quitError)).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 28).padding(.bottom, 12)
            }
        }
        .frame(minWidth: 480, idealWidth: 480, minHeight: 680)
        .background(colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.965))
        .tint(Color(red: 0.16, green: 0.36, blue: 0.96))
        .navigationTitle(AppCopy.value(.settings))
        .onAppear(perform: state.refresh)
        .onChange(of: editingSignal) { _ in showColorWheel = false }
        .sheet(isPresented: $state.removalIsPresented) { ManagedRemovalView(state: state) }
    }

    private func section<Content: View>(_ title: AppCopyKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.value(title)).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).padding(.leading, 2)
            content().padding(.horizontal, 14)
                .background(colorScheme == .dark ? Color(white: 0.145) : .white,
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.07),
                                      lineWidth: contrast == .increased ? 1 : 0.5)
                        .allowsHitTesting(false)
                }
        }
    }

    private var connectedDeviceName: String {
        if case .unverified(let interfaces) = state.snapshot.keyboardHealth {
            return Array(Set(interfaces.map { $0.model?.rawValue ?? $0.product })).sorted().joined(separator: ", ")
        }
        return AppCopy.value(.deviceName)
    }

    private var device: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(connectedDeviceName).font(.system(size: 14, weight: .semibold))
                    Text(AppCopy.value(state.menuState == .ready ? .statusUSBConnected : state.snapshot.keyboardHealth.copyKey))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showDiagnostics.toggle() } label: {
                    HStack(spacing: 5) {
                        Text(AppCopy.value(showDiagnostics ? .settingsHideDetails : .settingsDiagnosticDetails))
                        Image(systemName: showDiagnostics ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }.font(.system(size: 12)).padding(.vertical, 8)
                }.buttonStyle(.borderless)
            }.padding(.vertical, 14)
            Divider()
            CandidateKeyboardCatalogView()
            if showDiagnostics {
                Divider()
                DiagnosticsView(state: state).padding(.vertical, 14)
            }
            if state.migrationRequiresSignalPreview || state.previewRecord != nil {
                Divider()
                SignalPreviewFeedback(state: state, allowsRestart: true).padding(.vertical, 14)
            }
        }
    }

    private var signals: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([CodexSignal.execution, .attention, .completion], id: \.self) { signal in
                    Button { editingSignal = signal } label: {
                        Text(AppCopy.value(signal.shortCopyKey))
                            .font(.system(size: 12, weight: editingSignal == signal ? .semibold : .regular))
                            .foregroundStyle(editingSignal == signal ? Color.primary : .secondary)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(Color.primary.opacity(editingSignal == signal ? 0.075 : 0),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(editingSignal == signal ? [.isSelected] : [])
                }
            }.padding(.vertical, 10)
            Divider()
            row(.settingsVisibility) {
                Toggle(AppCopy.value(.settingsVisibility), isOn: Binding(
                    get: { appearance.isVisible }, set: { update(isVisible: $0) }
                )).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider()
            HStack {
                Text(AppCopy.value(.settingsColor))
                Spacer()
                Button(AppCopy.value(.settingsResetColor)) { state.resetSignalColor(for: editingSignal) }
                    .buttonStyle(.borderless).font(.system(size: 12))
                    .disabled(appearance.color == LocalProfile.default.appearance(for: editingSignal).color)
            }.frame(height: 38)
            colorEditor
            Divider()
            row(.settingsBrightness) {
                Slider(value: Binding(
                    get: { Double(appearance.brightness.percent) },
                    set: { if let value = SignalBrightness(percent: UInt8($0.rounded())) { update(brightness: value) } }
                ), in: 1...100, step: 1)
                    .frame(width: 182).accessibilityLabel(AppCopy.value(.settingsBrightness))
                Text("\(appearance.brightness.percent)%").monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Divider()
            row(.settingsSlowFlashing) {
                Toggle(AppCopy.value(.settingsSlowFlashing), isOn: Binding(
                    get: { appearance.pattern == .slowFlashing },
                    set: { update(pattern: $0 ? .slowFlashing : .steady) }
                )).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if editingSignal == .completion {
                Divider()
                row(.settingsCompletionDuration) {
                    Text("\(state.snapshot.profile.completionDisplayDuration.seconds) \(AppCopy.value(.settingsSeconds))")
                        .monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    Stepper(AppCopy.value(.settingsCompletionDuration), value: completionDuration, in: 1...60)
                        .labelsHidden().controlSize(.small).fixedSize()
                        .accessibilityValue("\(state.snapshot.profile.completionDisplayDuration.seconds) \(AppCopy.value(.settingsSeconds))")
                }
            }
        }.font(.system(size: 13))
    }

    private var colorEditor: some View {
        HStack(spacing: 12) {
            ForEach(SignalPalette.colors, id: \.name) { swatch in
                let selected = appearance.color == swatch.color
                Button { update(color: swatch.color) } label: {
                    Circle().fill(swatch.color.swiftUIColor).frame(width: 24, height: 24).padding(4)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.8 : 0.18),
                                                       lineWidth: selected ? 2 : 0.5))
                }.buttonStyle(InteractiveColorStyle())
                    .accessibilityLabel(AppCopy.value(swatch.name)).help(AppCopy.value(swatch.name))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Button { showColorWheel.toggle() } label: {
                Circle().fill(AngularGradient(colors: SignalColorWheel.spectrum, center: .center))
                    .overlay(Circle().fill(appearance.color.swiftUIColor).padding(6))
                    .frame(width: 24, height: 24).padding(4)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(showColorWheel ? 0.55 : 0.18)))
            }.buttonStyle(InteractiveColorStyle())
                .accessibilityLabel(AppCopy.value(.settingsColorWheel)).help(AppCopy.value(.settingsColorWheel))
                .popover(isPresented: $showColorWheel, arrowEdge: .bottom) {
                    SignalColorWheel(color: Binding(
                        get: { appearance.color.swiftUIColor },
                        set: { update(color: SignalColor(swiftUIColor: $0)) }
                    )).padding(18)
                }
            Spacer(minLength: 0)
        }.padding(.top, 4).padding(.bottom, 14)
    }

    private var general: some View {
        VStack(spacing: 0) {
            row(.settingsAppearance, height: 48) {
                HStack(spacing: 2) {
                    ForEach(AppAppearance.allCases, id: \.self) { choice in
                        let selected = state.preferences.appearance == choice
                        Button {
                            state.updatePreferences(AppPreferences(appearance: choice, language: state.preferences.language))
                        } label: {
                            Text(AppCopy.value(choice.copyKey))
                                .font(.system(size: 12, weight: selected ? .medium : .regular))
                                .frame(maxWidth: .infinity).frame(height: 26)
                                .background {
                                    if selected {
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(colorScheme == .dark ? Color(white: 0.27) : .white)
                                            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                                    }
                                }
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }.padding(3).frame(width: 240)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(AppCopy.value(.settingsAppearance))
            }
            Divider()
            row(.settingsLanguage, height: 44) {
                Picker(AppCopy.value(.settingsLanguage), selection: Binding(
                    get: { state.preferences.language },
                    set: { state.updatePreferences(AppPreferences(appearance: state.preferences.appearance, language: $0)) }
                )) {
                    Text(AppCopy.value(.settingsFollowSystem)).tag(AppLanguageChoice.system)
                    Text("简体中文").tag(AppLanguageChoice.simplifiedChinese)
                    Text("English").tag(AppLanguageChoice.english)
                }.labelsHidden().frame(width: 152)
            }
            Divider()
            row(.settingsLoginLaunch, height: 44) {
                Toggle(AppCopy.value(.settingsLoginLaunch), isOn: Binding(
                    get: { state.loginLaunchEnabled }, set: { state.updateLoginLaunch($0) }
                )).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }.font(.system(size: 13))
    }

    private func row<Content: View>(_ key: AppCopyKey, height: CGFloat = 40, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(AppCopy.value(key))
            Spacer(minLength: 10)
            content()
        }.frame(minHeight: height)
    }

    private var completionDuration: Binding<Int> {
        Binding(
            get: { Int(state.snapshot.profile.completionDisplayDuration.seconds) },
            set: { if let duration = CompletionDisplayDuration(seconds: UInt8($0)) { state.updateCompletionDisplayDuration(duration) } }
        )
    }

    @ViewBuilder private var errors: some View {
        if state.settingsFailed { Text(AppCopy.value(.settingsSaveError)).foregroundStyle(.red) }
        if state.validationFailed { Text(AppCopy.value(.settingsValidationError)).foregroundStyle(.red) }
        if state.previewStateFailed { Text(AppCopy.value(.previewStateError)).foregroundStyle(.red) }
    }

    private func update(
        isVisible: Bool? = nil, color: SignalColor? = nil,
        brightness: SignalBrightness? = nil, pattern: SignalPattern? = nil
    ) {
        let current = appearance
        state.updateAppearance(SignalAppearance(
            isVisible: isVisible ?? current.isVisible, color: color ?? current.color,
            brightness: brightness ?? current.brightness, pattern: pattern ?? current.pattern
        ), for: editingSignal)
    }
}

extension CodexSignal {
    var shortCopyKey: AppCopyKey {
        switch self {
        case .execution: .executionShort
        case .attention: .attentionShort
        case .completion: .completionShort
        }
    }
}

private extension AppAppearance {
    var copyKey: AppCopyKey {
        switch self {
        case .system: .settingsFollowSystem
        case .light: .settingsLight
        case .dark: .settingsDark
        }
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
