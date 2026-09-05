import AppKit
import KeyphoreCore
import SwiftUI

struct SignalSettingsView: View {
    @ObservedObject var state: KeyphoreAppState
    let checkForUpdates: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var editingSignal: CodexSignal = .execution
    @State private var showColorWheel = false

    private var appearance: SignalAppearance { state.snapshot.profile.appearance(for: editingSignal) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsTabPicker(selection: $state.selectedSettingsTab, language: state.preferences.resolvedLanguage())
                .frame(width: 320, height: 64)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch state.selectedSettingsTab {
                    case .lights:
                        section(.settingsSignals) { signals }
                    case .device:
                        section(.settingsDevice) { device }
                        section(.deviceCheckTitle) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(AppCopy.value(.deviceCheckIntro)).font(.caption).foregroundStyle(.secondary)
                                SignalPreviewFeedback(state: state, allowsRestart: true)
                                Divider()
                                DiagnosticsView(state: state)
                            }.padding(.vertical, 14)
                        }
                    case .general:
                        section(.settingsGeneral) { general }
                    case .about:
                        about
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
            .disabled(state.isStarting)
            .id(state.selectedSettingsTab)
            VStack(alignment: .leading, spacing: 6) { errors }
                .font(.caption).padding(.horizontal, 28)
            Divider()
            HStack {
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Label(AppCopy.value(.quit), systemImage: "power")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(.bordered).controlSize(.regular)
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            if state.quitFailed {
                Text(AppCopy.value(.quitError)).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 28).padding(.bottom, 12)
            }
        }
        .frame(minWidth: 480, idealWidth: 480, minHeight: 600)
        .background(colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.965))
        .tint(Color(red: 0.16, green: 0.36, blue: 0.96))
        .environment(\.locale, Locale(identifier: state.preferences.resolvedLanguage().rawValue))
        .navigationTitle(AppCopy.value(.settings))
        .onAppear(perform: state.refresh)
        .onChange(of: editingSignal) { _ in showColorWheel = false }
        .onChange(of: state.selectedSettingsTab) { _ in showColorWheel = false }
        .sheet(isPresented: $state.removalIsPresented) { ManagedRemovalView(state: state) }
    }

    private var about: some View {
        KeyphoreAboutView(language: state.preferences.resolvedLanguage(),
                          checkForUpdates: checkForUpdates,
                          removeManagedComponents: state.canManageRemoval ? { state.presentManagedRemoval() } : nil)
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
        return state.snapshot.keyboardHealth.model?.rawValue ?? AppCopy.value(.deviceName)
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
            }.padding(.vertical, 14)
            Divider()
            CandidateKeyboardCatalogView()
            if state.experimentalRecords.contains(where: { $0.identity.isEligible && $0.identity.model?.rawValue == connectedDeviceName }) {
                Divider()
                ExperimentalKeyboardSettingsView(state: state)
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
                            .contentShape(Rectangle())
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
                ), in: 1...100)
                    .frame(width: 182).accessibilityLabel(AppCopy.value(.settingsBrightness))
                    .accessibilityValue("\(appearance.brightness.percent)%")
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
                                .contentShape(Rectangle())
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
                    ForEach(AppLanguageChoice.allCases.filter { $0 != .system }, id: \.self) { choice in
                        if let language = choice.language {
                            Text(language.nativeName).tag(choice)
                        }
                    }
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

private struct SettingsTabPicker: View {
    @Binding var selection: SettingsTab
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 23, weight: .regular))
                            .frame(width: 30, height: 28)
                            .accessibilityHidden(true)
                        Text(AppCopy.value(tab.copyKey, language: language))
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(SettingsTabButtonStyle(isSelected: selection == tab))
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppCopy.value(.settings, language: language))
    }
}

private struct SettingsTabButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color(nsColor: .controlAccentColor) : .secondary)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : isSelected ? 0.07 : 0))
            }
            .overlay {
                if isSelected && contrast == .increased {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                }
            }
    }
}

enum SettingsTab: CaseIterable {
    case lights, device, general, about

    var symbolName: String {
        switch self {
        case .lights: "lightbulb"
        case .device: "keyboard"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }

    var copyKey: AppCopyKey {
        switch self {
        case .lights: .settingsTabLights
        case .device: .settingsTabDevice
        case .general: .settingsGeneral
        case .about: .settingsTabAbout
        }
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

struct ExperimentalKeyboardSettingsView: View {
    @ObservedObject var state: KeyphoreAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppCopy.value(.experimentalTitle)).font(.subheadline.weight(.semibold))
            Text(AppCopy.value(.experimentalDetail)).font(.caption).foregroundStyle(.secondary)
            ForEach(state.experimentalRecords.filter { $0.identity.isEligible }, id: \.identity) { record in
                Divider()
                Text(record.identity.model?.rawValue ?? record.identity.product).font(.subheadline.weight(.medium))
                Text(String(format: "USB %04X · REV %04X", Int(record.identity.productID), record.identity.usbRevision))
                    .font(.caption).foregroundStyle(.secondary)
                Text(AppCopy.value(status(record.phase))).font(.caption)
                switch record.phase {
                case .available, .failed, .disabled:
                    Button(AppCopy.value(.experimentalStart)) { state.updateExperimental(record.identity, action: "start") }
                case .awaitingConfirmation:
                    Button(AppCopy.value(.experimentalConfirmAction)) { state.updateExperimental(record.identity, action: "confirm") }
                    Button(AppCopy.value(.experimentalDisable)) { state.updateExperimental(record.identity, action: "disable") }
                case .requested, .testing, .enabled:
                    Button(AppCopy.value(.experimentalDisable)) { state.updateExperimental(record.identity, action: "disable") }
                case .revoking:
                    ProgressView().controlSize(.small)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 14)
    }

    private func status(_ phase: ExperimentalKeyboardRecord.Phase) -> AppCopyKey {
        switch phase {
        case .available: .experimentalAvailable
        case .requested, .testing: .experimentalTesting
        case .awaitingConfirmation: .experimentalConfirm
        case .enabled: .experimentalEnabled
        case .revoking: .experimentalRevoking
        case .disabled: .experimentalDisabled
        case .failed: .experimentalFailed
        }
    }
}

private struct KeyphoreAboutView: View {
    let language: AppLanguage
    let checkForUpdates: () -> Void
    var removeManagedComponents: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private func copy(_ key: AppCopyKey) -> String {
        AppCopy.value(key, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Keyphore").font(.system(size: 24, weight: .semibold))
                    Text(copy(.aboutDescription))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: copy(.aboutVersion),
                                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                                Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button(action: checkForUpdates) {
                    Label(copy(.checkForUpdates), systemImage: "arrow.triangle.2.circlepath")
                }
                Link(destination: URL(string: "https://github.com/BarryBarrywu/Keyphore")!) {
                    Label("GitHub", systemImage: "arrow.up.right")
                }
            }
            .buttonStyle(.bordered).controlSize(.regular).font(.system(size: 12))

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(copy(.aboutMyWork)).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link(destination: URL(string: "https://barrybarrywu.com")!) {
                        Label(copy(.aboutMoreApps), systemImage: "arrow.up.right")
                    }.font(.system(size: 11)).buttonStyle(.borderless)
                }
                Link(destination: URL(string: language == .simplifiedChinese
                     ? "https://tutti.barrybarrywu.com/zh/" : "https://tutti.barrybarrywu.com/")!) {
                    HStack(spacing: 12) {
                        Image("TuttiIcon").resizable().scaledToFit().frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tutti").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                            Text(copy(.aboutTuttiTagline)).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(borderColor))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).accessibilityLabel(copy(.aboutExploreTutti))
            }

            HStack(spacing: 10) {
                Text(copy(.aboutFollowDeveloper)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if language == .simplifiedChinese {
                    socialLink("小红书", image: nil, tint: Color(red: 0.92, green: 0.22, blue: 0.33),
                               url: "https://www.xiaohongshu.com/user/profile/64c9b594000000000e0263f1")
                    socialLink("哔哩哔哩", image: "BrandBilibili", tint: Color(red: 0, green: 0.64, blue: 0.85),
                               url: "https://space.bilibili.com/217963572")
                } else {
                    socialLink("X", image: "BrandX", tint: .primary, url: "https://x.com/BarryBarrywu")
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 16) {
                if let removeManagedComponents {
                    Button(role: .destructive, action: removeManagedComponents) {
                        HStack(spacing: 9) {
                            Image(systemName: "shippingbox").foregroundStyle(.secondary)
                            Text(copy(.removalAction)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12)).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Text("© 2026 Barry Barry Wu").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }

    private var cardBackground: Color {
        colorScheme == .dark ? Color(white: 0.15) : .white
    }

    private var borderColor: Color {
        Color.primary.opacity(contrast == .increased ? 0.45 : 0.09)
    }

    private func socialLink(_ title: String, image: String?, tint: Color, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 7) {
                if let image {
                    Image(image).renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 16, height: 16)
                        .foregroundStyle(tint).accessibilityHidden(true)
                }
                if image != "BrandX" {
                    Text(verbatim: title).foregroundStyle(image == nil ? tint : .primary)
                }
            }
            .font(.system(size: 11)).foregroundStyle(.primary)
            .padding(.horizontal, 12).frame(height: 32)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(borderColor))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.borderless).accessibilityLabel(title)
    }
}
