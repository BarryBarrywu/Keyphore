import AppKit
import KeyphoreCore
import SwiftUI

struct SignalSettingsView: View {
    @ObservedObject var state: KeyphoreAppState
    let checkForUpdates: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var editingPreset: LightingPreset = .execution
    @State private var editingZone: LightingZone = .backlight

    private var appearance: SignalAppearance { state.snapshot.profile.appearance(forPreset: editingPreset) }
    private var keyboardModel: SupportedKeyboardModel? { state.activeKeyboardModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsTabPicker(selection: $state.selectedSettingsTab, language: state.preferences.resolvedLanguage())
                .frame(width: 400, height: 64)
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
                    case .integrations:
                        section(.integrationsTitle) {
                            AgentIntegrationsView(state: state)
                                .padding(.vertical, 14)
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
        .frame(minWidth: 1000, idealWidth: 1040, minHeight: 700)
        .background(colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.965))
        .tint(Color(red: 0.16, green: 0.36, blue: 0.96))
        .environment(\.locale, Locale(identifier: state.preferences.resolvedLanguage().rawValue))
        .navigationTitle(AppCopy.value(.settings))
        .onAppear {
            state.refresh()
            resetEditingZoneIfNeeded()
        }
        .onChange(of: keyboardModel?.rawValue) { _ in resetEditingZoneIfNeeded() }
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
            if state.canSelectKeyboard {
                KeyboardTargetSelectionView(state: state)
                Divider()
            }
            CandidateKeyboardCatalogView()
            if state.experimentalRecords.contains(where: { $0.identity.isEligible && $0.identity.model?.rawValue == connectedDeviceName }) {
                Divider()
                ExperimentalKeyboardSettingsView(state: state)
            }
        }
    }

    private var signals: some View {
        let expectedModel = state.profileModel
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                ForEach(LightingPreset.allCases, id: \.self) { preset in
                    Button {
                        editingPreset = preset
                        state.beginSignalPreview(for: preset)
                    } label: {
                        Text(AppCopy.value(preset.shortCopyKey))
                            .font(.system(size: 12, weight: editingPreset == preset ? .semibold : .regular))
                            .foregroundStyle(editingPreset == preset ? Color.primary : .secondary)
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .contentShape(Rectangle())
                            .background(Color.primary.opacity(editingPreset == preset ? 0.075 : 0),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(editingPreset == preset ? [.isSelected] : [])
                }
            }
            HStack(spacing: 16) {
                HStack(spacing: 2) {
                    ForEach(signalSettingsControlledZones(for: keyboardModel), id: \.rawValue) { zones in
                        Button(AppCopy.value(zones.copyKey)) {
                            selectControlledZones(zones, expectedModel: expectedModel)
                        }
                            .buttonStyle(.bordered)
                            .tint(state.snapshot.profile.controlledZones == zones ? .accentColor : .secondary)
                            .accessibilityAddTraits(state.snapshot.profile.controlledZones == zones ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(AppCopy.value(.settingsControlledZones))
                Spacer()
                if editingPreset == .idle {
                    HStack(spacing: 8) {
                        Text(AppCopy.value(.settingsIdleBehavior)).foregroundStyle(.secondary)
                        Picker(AppCopy.value(.settingsIdleBehavior), selection: Binding(
                            get: { appearance.isVisible },
                            set: { updateVisibility($0, expectedModel: expectedModel) }
                        )) {
                            Text(AppCopy.value(.settingsIdleOff)).tag(false)
                            Text(AppCopy.value(.settingsIdleCustom)).tag(true)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 300)
                    }
                } else {
                    Toggle(AppCopy.value(.settingsVisibility), isOn: Binding(
                        get: { appearance.isVisible },
                        set: { updateVisibility($0, expectedModel: expectedModel) }
                    )).toggleStyle(.switch).controlSize(.small)
                }
            }.disabled(!state.keyboardProfileAllowsEditing)
            if editingPreset == .idle {
                Text(AppCopy.value(.settingsIdleDetail)).font(.caption).foregroundStyle(.secondary)
            }
            if keyboardModel == .air75V2 {
                Label(AppCopy.value(.settingsAir75V2Capabilities), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if state.canSelectKeyboard && !state.keyboardSelectionIsApplied {
                Label(AppCopy.value(.keyboardSelectionPreviewUnavailable), systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !state.keyboardProfileAllowsEditing {
                Label(AppCopy.value(.keyboardProfileUnavailable), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if !state.canPreviewLighting {
                Label(AppCopy.value(.keyboardProfilePreviewUnavailable), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 18) {
                zonePanel
                VStack(alignment: .leading, spacing: 16) {
                    effectPanel
                    parameterPanel
                }
                colorPanel
            }.disabled(!state.keyboardProfileAllowsEditing)
            if editingPreset == .completion {
                row(.settingsCompletionDuration) {
                    Text("\(state.snapshot.profile.completionDisplayDuration.seconds) \(AppCopy.value(.settingsSeconds))")
                        .monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    Stepper(
                        AppCopy.value(.settingsCompletionDuration),
                        value: completionDuration(expectedModel: expectedModel), in: 1...60
                    )
                        .labelsHidden().controlSize(.small).fixedSize()
                }.disabled(!state.keyboardProfileAllowsEditing)
            }
        }.font(.system(size: 13)).padding(.vertical, 12)
    }

    private var zonePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelTitle(.settingsZones)
            ForEach(signalSettingsLightingZones(for: keyboardModel), id: \.rawValue) { zone in
                let managed = state.snapshot.profile.controlledZones.contains(zone)
                let editable = signalSettingsZoneIsEditable(zone, model: keyboardModel)
                Button { editingZone = zone } label: {
                    HStack {
                        Circle().fill(appearance.appearance(for: zone).color.swiftUIColor).frame(width: 14, height: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppCopy.value(
                                keyboardModel == .air75V2 && zone == .strip
                                    ? .settingsAir75V2StripUnsupported : zone.copyKey
                            )).fontWeight(editingZone == zone ? .semibold : .regular)
                            Text(AppCopy.value(
                                keyboardModel == .air75V2 && zone == .strip
                                    ? .settingsAir75V2StripDetail
                                    : managed ? .settingsManaged : .settingsUnmanaged
                            ))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if editingZone == zone { Image(systemName: "checkmark") }
                    }.padding(9).contentShape(Rectangle())
                        .background(Color.primary.opacity(editingZone == zone ? 0.07 : 0),
                                    in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).disabled(!editable)
            }
            Divider()
            panelTitle(.settingsLightingPreview)
            Air65KeyboardView(presentation: KeyboardSignalPresentation(
                signal: editingPreset.aggregateSignal, appearance: appearance,
                controlledZones: keyboardModel == .air75V2 ? .backlight : state.snapshot.profile.controlledZones
            ), layout: keyboardLayout(for: keyboardModel), model: keyboardModel)
                .frame(width: 180, height: 82)
            Text(AppCopy.value(.settingsPreviewApproximate))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(width: 180, alignment: .leading)
    }

    private var effectPanel: some View {
        let expectedModel = state.profileModel
        return VStack(alignment: .leading, spacing: 8) {
            panelTitle(.settingsNativeEffect)
            if state.snapshot.profile.controlledZones.contains(editingZone) {
                Group {
                    if keyboardModel == .air75V2 {
                        ScrollView { effectGrid(expectedModel: expectedModel) }
                            .frame(height: 230)
                    } else {
                        effectGrid(expectedModel: expectedModel)
                    }
                }
            } else {
                Label(AppCopy.value(.settingsZoneUnmanagedDetail), systemImage: "minus.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            }
        }.frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
            .disabled(editingPreset == .idle && !appearance.isVisible)
    }

    private func effectGrid(expectedModel: SupportedKeyboardModel?) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(signalSettingsEffects(for: editingZone, model: keyboardModel), id: \.rawValue) { effect in
                Button { updateZone(effect: effect, expectedModel: expectedModel) } label: {
                    Text(signalSettingsEffectLabel(effect, model: keyboardModel))
                        .font(.caption)
                        .lineLimit(keyboardModel == .air75V2 ? 2 : 1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, minHeight: keyboardModel == .air75V2 ? 36 : 30)
                        .background(Color.primary.opacity(zoneAppearance.effect == effect ? 0.1 : 0.035),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(signalSettingsEffectLabel(effect, language: .english, model: keyboardModel))
                .accessibilityAddTraits(zoneAppearance.effect == effect ? .isSelected : [])
            }
        }
    }

    private var parameterPanel: some View {
        let expectedModel = state.profileModel
        return VStack(alignment: .leading, spacing: 12) {
            panelTitle(.settingsParameters)
            parameterSlider(.settingsBrightness, value: Double(zoneAppearance.brightness.percent), range: 0...100) {
                if let value = SignalBrightness(percent: UInt8($0.rounded())) {
                    updateZone(brightness: value, expectedModel: expectedModel)
                }
            }
            if keyboardModel?.supportsSpeed(for: zoneAppearance.effect) ?? zoneAppearance.effect.supportsSpeed {
                parameterSlider(.settingsSpeed, value: Double(zoneAppearance.speed.level), range: 0...4) {
                    if let value = LightingSpeed(level: UInt8($0.rounded())) {
                        updateZone(speed: value, expectedModel: expectedModel)
                    }
                }
            }
            if keyboardModel?.supportsDirection(for: zoneAppearance.effect) ?? (zoneAppearance.effect.directionAxis != nil),
               let axis = zoneAppearance.effect.directionAxis {
                HStack(spacing: 2) {
                    directionButton(
                        .forward, key: axis == .horizontal ? .settingsDirectionLeft : .settingsDirectionUp,
                        expectedModel: expectedModel
                    )
                    directionButton(
                        .reverse, key: axis == .horizontal ? .settingsDirectionRight : .settingsDirectionDown,
                        expectedModel: expectedModel
                    )
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(AppCopy.value(.settingsDirection))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .disabled(editorIsDisabled)
    }

    private var colorPanel: some View {
        let expectedModel = state.profileModel
        return NativeColorPanel(
            appearance: zoneAppearance,
            keyboardModel: keyboardModel,
            reset: {
                updateZone(
                    color: LocalProfile.default.appearance(forPreset: editingPreset)
                        .appearance(for: editingZone).color,
                    colorMode: .custom, expectedModel: expectedModel
                )
            },
            updateColorMode: { updateZone(colorMode: $0, expectedModel: expectedModel) },
            updateColor: { updateZone(color: $0, colorMode: .custom, expectedModel: expectedModel) }
        )
        .frame(width: 430, alignment: .leading)
        .disabled(editorIsDisabled)
    }

    private func panelTitle(_ key: AppCopyKey) -> some View {
        Text(AppCopy.value(key)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func directionButton(
        _ direction: LightingDirection, key: AppCopyKey,
        expectedModel: SupportedKeyboardModel?
    ) -> some View {
        Button(AppCopy.value(key)) { updateZone(direction: direction, expectedModel: expectedModel) }
            .buttonStyle(.bordered)
            .tint(zoneAppearance.direction == direction ? .accentColor : .secondary)
            .accessibilityAddTraits(zoneAppearance.direction == direction ? .isSelected : [])
    }

    private func parameterSlider(
        _ key: AppCopyKey, value: Double, range: ClosedRange<Double>,
        update: @escaping @MainActor @Sendable (Double) -> Void
    ) -> some View {
        let displayValue = "\(Int(value))" + (key == .settingsBrightness ? "%" : "")
        let binding = Binding(get: { value }, set: { newValue in
            MainActor.assumeIsolated { update(newValue) }
        })
        return VStack(alignment: .leading, spacing: 4) {
            HStack { Text(AppCopy.value(key)); Spacer(); Text(displayValue).monospacedDigit().foregroundStyle(.secondary) }
            Group {
                if key == .settingsBrightness {
                    Slider(value: binding, in: range)
                } else {
                    Slider(value: binding, in: range, step: 1)
                }
            }.accessibilityLabel(AppCopy.value(key)).accessibilityValue(displayValue)
        }
    }

    private var zoneAppearance: ZoneAppearance { appearance.appearance(for: editingZone) }
    private var editorIsDisabled: Bool {
        !state.snapshot.profile.controlledZones.contains(editingZone)
            || !(keyboardModel?.supportedEffects(for: editingZone).contains(zoneAppearance.effect) ?? true)
            || (editingPreset == .idle && !appearance.isVisible)
    }

    private func selectControlledZones(
        _ zones: ControlledZones, expectedModel: SupportedKeyboardModel?
    ) {
        guard let expectedModel,
              state.updateControlledZones(zones, expectedModel: expectedModel) else { return }
        if !zones.contains(editingZone) { editingZone = zones == .backlight ? .backlight : .strip }
        if editingPreset == .idle { state.beginSignalPreview(for: .idle, expectedModel: expectedModel) }
    }

    private func resetEditingZoneIfNeeded() {
        if !signalSettingsZoneIsEditable(editingZone, model: keyboardModel) {
            editingZone = .backlight
        }
    }

    private func updateVisibility(
        _ isVisible: Bool, expectedModel: SupportedKeyboardModel?
    ) {
        guard let expectedModel else { return }
        state.updateAppearance(SignalAppearance(
            isVisible: isVisible, backlight: appearance.backlight, strip: appearance.strip
        ), for: editingPreset, expectedModel: expectedModel)
    }

    private func updateZone(
        effect: NativeLightingEffect? = nil, color: SignalColor? = nil,
        colorMode: SignalColorMode? = nil, brightness: SignalBrightness? = nil,
        speed: LightingSpeed? = nil, direction: LightingDirection? = nil,
        expectedModel: SupportedKeyboardModel? = nil
    ) {
        guard let expectedModel else { return }
        let current = zoneAppearance
        let selectedEffect = effect ?? current.effect
        let supportsMulticolor = keyboardModel?.supportsMulticolor(for: selectedEffect)
            ?? selectedEffect.supportsMulticolor
        let updated = ZoneAppearance(
            effect: selectedEffect, color: color ?? current.color,
            colorMode: supportsMulticolor ? (colorMode ?? current.colorMode) : .custom,
            brightness: brightness ?? current.brightness,
            speed: speed ?? current.speed,
            direction: signalSettingsDirection(
                current: current.direction, requested: direction,
                effect: selectedEffect, model: keyboardModel
            )
        )
        state.updateAppearance(
            appearance.replacingAppearance(updated, for: editingZone),
            for: editingPreset, expectedModel: expectedModel
        )
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

    private func completionDuration(expectedModel: SupportedKeyboardModel?) -> Binding<Int> {
        Binding(
            get: { Int(state.snapshot.profile.completionDisplayDuration.seconds) },
            set: {
                if let expectedModel,
                   let duration = CompletionDisplayDuration(seconds: UInt8($0)) {
                    state.updateCompletionDisplayDuration(duration, expectedModel: expectedModel)
                }
            }
        )
    }

    @ViewBuilder private var errors: some View {
        if state.settingsFailed { Text(AppCopy.value(.settingsSaveError)).foregroundStyle(.red) }
        if state.validationFailed { Text(AppCopy.value(.settingsValidationError)).foregroundStyle(.red) }
        if state.previewStateFailed { Text(AppCopy.value(.previewStateError)).foregroundStyle(.red) }
    }

}

struct KeyboardTargetOption: Equatable, Identifiable {
    let model: SupportedKeyboardModel?
    let connectedCount: Int
    var id: String { model?.rawValue ?? "" }
}

func keyboardTargetOptions(
    desired: SupportedKeyboardModel?, snapshot: KeyboardSelectionSnapshot?
) -> [KeyboardTargetOption] {
    guard let snapshot else {
        return [KeyboardTargetOption(model: nil, connectedCount: 0)]
            + (desired.map { [KeyboardTargetOption(model: $0, connectedCount: 0)] } ?? [])
    }
    var models = snapshot.inventory.map(\.model)
    if let desired, !models.contains(desired) { models.append(desired) }
    let ordered = SupportedKeyboardModel.selectableModels.filter { models.contains($0) }
    return [KeyboardTargetOption(model: nil, connectedCount: snapshot.inventory.reduce(0) { $0 + $1.count })]
        + ordered.map { model in
            KeyboardTargetOption(
                model: model,
                connectedCount: snapshot.inventory.first { $0.model == model }?.count ?? 0
            )
        }
}

func keyboardSelectionStatusKey(
    desired: SupportedKeyboardModel?, snapshot: KeyboardSelectionSnapshot?, failed: Bool
) -> AppCopyKey? {
    if failed { return .keyboardSelectionError }
    guard let snapshot else { return .keyboardSelectionUnavailable }
    if snapshot.failure == .discoveryFailed || snapshot.failure == .stateUnavailable {
        return .keyboardSelectionUnavailable
    }
    if snapshot.failure == .unsupportedSelection { return .keyboardSelectionUnsupported }
    if snapshot.phase == .blocked && snapshot.failure == nil { return .keyboardSelectionUnavailable }
    if snapshot.inventory.allSatisfy({ $0.count == 0 }) { return .keyboardSelectionNoConnected }
    if desired != snapshot.desiredModel || snapshot.phase == .pending { return .keyboardSelectionPending }
    guard snapshot.phase == .blocked else { return nil }
    switch snapshot.failure {
    case .notFound: return .keyboardSelectionNotFound
    case .ambiguous:
        if let desired, (snapshot.inventory.first { $0.model == desired }?.count ?? 0) > 1 {
            return .keyboardSelectionDuplicate
        }
        return snapshot.inventory.contains { $0.count == 1 } ? .keyboardSelectionChooseTarget : .keyboardSelectionDuplicate
    case .oldTargetUnavailable, .oldTargetOffFailed: return .keyboardSelectionOldTargetFailed
    case .unsupportedSelection: return .keyboardSelectionUnsupported
    case .discoveryFailed, .stateUnavailable, nil: return .keyboardSelectionUnavailable
    }
}

private struct KeyboardTargetSelectionView: View {
    @ObservedObject var state: KeyphoreAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppCopy.value(.keyboardSelectionTitle)).font(.system(size: 13, weight: .semibold))
                    Text(AppCopy.value(.keyboardSelectionDetail)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(AppCopy.value(.keyboardSelectionTitle), selection: Binding(
                    get: { state.desiredKeyboardModel?.rawValue ?? "" },
                    set: { value in
                        state.requestKeyboardSelection(
                            value.isEmpty ? nil : SupportedKeyboardModel(rawValue: value)
                        )
                    }
                )) {
                    ForEach(state.keyboardSelectionOptions) { option in
                        Text(state.keyboardTargetLabel(option)).tag(option.id)
                            .disabled(!state.canRequestKeyboardSelection(option.model))
                    }
                }
                .frame(width: 310)
                .disabled(!state.canRequestKeyboardSelection(nil))
            }
            HStack(spacing: 6) {
                Text(AppCopy.value(.keyboardSelectionActive)).foregroundStyle(.secondary)
                Text(state.keyboardSelectionActiveLabel)
                    .fontWeight(.medium)
            }.font(.caption)
            if let key = state.keyboardSelectionMessageKey {
                Label(AppCopy.value(key), systemImage: key == .keyboardSelectionPending ? "hourglass" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(
                        key == .keyboardSelectionPending ? Color.secondary : Color.orange
                    )
            }
        }.padding(.vertical, 14)
    }

}

func signalSettingsControlledZones(for model: SupportedKeyboardModel?) -> [ControlledZones] {
    ControlledZones.allCases.filter { model?.supportsStripLighting != false || $0 == .backlight }
}

func signalSettingsLightingZones(for model: SupportedKeyboardModel?) -> [LightingZone] {
    LightingZone.allCases
}

func signalSettingsZoneIsEditable(
    _ zone: LightingZone, model: SupportedKeyboardModel?
) -> Bool {
    model?.supportedEffects(for: zone).isEmpty != true
}

func signalSettingsEffects(
    for zone: LightingZone, model: SupportedKeyboardModel?
) -> [NativeLightingEffect] {
    model?.supportedEffects(for: zone) ?? NativeLightingEffect.catalog(for: zone)
}

func signalSettingsDirection(
    current: LightingDirection, requested: LightingDirection?,
    effect: NativeLightingEffect, model: SupportedKeyboardModel?
) -> LightingDirection {
    let isSupported = model?.supportsDirection(for: effect) ?? (effect.directionAxis != nil)
    return isSupported ? (requested ?? current) : .forward
}

func keyboardLayout(for model: SupportedKeyboardModel?) -> Air65KeyboardView.Layout {
    model == .air75V3 || model == .air75V2 ? .air75ANSI : .air65
}

struct NativeColorPanel: View {
    let appearance: ZoneAppearance
    var keyboardModel: SupportedKeyboardModel? = nil
    let reset: @MainActor @Sendable () -> Void
    let updateColorMode: @MainActor @Sendable (SignalColorMode) -> Void
    let updateColor: @MainActor @Sendable (SignalColor) -> Void

    @ViewBuilder var body: some View {
        if keyboardModel?.supportsColor(for: appearance.effect) ?? appearance.effect.supportsColor {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(AppCopy.value(.settingsCustomColor)).font(.caption.weight(.semibold))
                    Spacer()
                    Button(AppCopy.value(.settingsResetColor), action: reset)
                        .buttonStyle(.borderless).font(.caption)
                    Toggle(AppCopy.value(.settingsCustomColor), isOn: Binding(
                    get: {
                        !(keyboardModel?.supportsMulticolor(for: appearance.effect)
                            ?? appearance.effect.supportsMulticolor) || appearance.colorMode == .custom
                    },
                    set: { isCustom in
                        MainActor.assumeIsolated { updateColorMode(isCustom ? .custom : .multicolor) }
                    }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!(keyboardModel?.supportsMulticolor(for: appearance.effect)
                        ?? appearance.effect.supportsMulticolor))
                    .accessibilityLabel(AppCopy.value(.settingsCustomColor))
                }
                SignalColorWheel(color: Binding(get: { appearance.color }, set: { color in
                    MainActor.assumeIsolated { updateColor(color) }
                }))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(AppCopy.value(.settingsColor)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(AppCopy.value(.settingsAutomaticColors)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

func signalSettingsEffectLabel(
    _ effect: NativeLightingEffect, language: AppLanguage? = nil,
    model: SupportedKeyboardModel? = nil
) -> String {
    let key: AppCopyKey
    if model == .air75V2, effect == .backlightStatic {
        key = .effectViaSolidColor
    } else if model == .air75V2, effect == .backlightBreathing {
        key = .effectViaBreathing
    } else {
        key = effect.copyKey
    }
    if let language { return AppCopy.value(key, language: language) }
    return AppCopy.value(key)
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
    case lights, device, integrations, general, about

    var symbolName: String {
        switch self {
        case .lights: "lightbulb"
        case .device: "keyboard"
        case .integrations: "terminal"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }

    var copyKey: AppCopyKey {
        switch self {
        case .lights: .settingsTabLights
        case .device: .settingsTabDevice
        case .integrations: .settingsTabIntegrations
        case .general: .settingsGeneral
        case .about: .settingsTabAbout
        }
    }
}

extension LightingPreset {
    var shortCopyKey: AppCopyKey {
        switch self {
        case .execution: .executionShort
        case .attention: .attentionShort
        case .completion: .completionShort
        case .idle: .settingsIdle
        }
    }

    var aggregateSignal: AggregateSignal {
        switch self {
        case .execution: .execution
        case .attention: .attention
        case .completion: .completion
        case .idle: .signalOff
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

private extension LightingZone {
    var copyKey: AppCopyKey { self == .backlight ? .settingsBacklight : .settingsStrip }
}

private extension ControlledZones {
    var copyKey: AppCopyKey {
        switch self {
        case .backlight: .settingsManageBacklight
        case .strip: .settingsManageStrip
        case .both: .settingsManageBoth
        }
    }
}

private extension NativeLightingEffect {
    var copyKey: AppCopyKey {
        switch self {
        case .backlightSpectrum: .effectSpectrum
        case .backlightGradient: .effectGradient
        case .backlightStatic, .stripStatic: .effectStatic
        case .backlightBreathing, .stripBreathing: .effectBreathing
        case .backlightFlowers: .effectFlowers
        case .backlightWave: .effectWave
        case .backlightUpDownWave: .effectUpDownWave
        case .backlightFountain: .effectFountain
        case .backlightGalaxy: .effectGalaxy
        case .backlightRotation: .effectRotation
        case .backlightRipple: .effectRipple
        case .backlightSinglePoint: .effectSinglePoint
        case .backlightGrid: .effectGrid
        case .backlightFlowing, .stripFlowing: .effectFlowing
        case .backlightRain: .effectRain
        case .backlightWaveBand: .effectWaveBand
        case .backlightGaming: .effectGaming
        case .backlightIdentify: .effectIdentify
        case .backlightWindmill: .effectWindmill
        case .backlightDiagonal: .effectDiagonal
        case .stripRhythm: .effectRhythm
        case .stripNeon: .effectNeon
        case .viaOff: .effectViaOff
        case .viaGradientUpDown: .effectViaGradientUpDown
        case .viaGradientLeftRight: .effectViaGradientLeftRight
        case .viaBandSaturation: .effectViaBandSaturation
        case .viaBandValue: .effectViaBandValue
        case .viaPinwheelSaturation: .effectViaPinwheelSaturation
        case .viaPinwheelValue: .effectViaPinwheelValue
        case .viaSpiralSaturation: .effectViaSpiralSaturation
        case .viaSpiralValue: .effectViaSpiralValue
        case .viaCycleAll: .effectViaCycleAll
        case .viaCycleLeftRight: .effectViaCycleLeftRight
        case .viaCycleUpDown: .effectViaCycleUpDown
        case .viaRainbowMovingChevron: .effectViaRainbowMovingChevron
        case .viaCycleOutIn: .effectViaCycleOutIn
        case .viaCycleOutInDual: .effectViaCycleOutInDual
        case .viaCyclePinwheel: .effectViaCyclePinwheel
        case .viaCycleSpiral: .effectViaCycleSpiral
        case .viaDualBeacon: .effectViaDualBeacon
        case .viaRainbowBeacon: .effectViaRainbowBeacon
        case .viaRainbowPinwheels: .effectViaRainbowPinwheels
        case .viaRaindrops: .effectViaRaindrops
        case .viaJellybeanRaindrops: .effectViaJellybeanRaindrops
        case .viaHueBreathing: .effectViaHueBreathing
        case .viaHuePendulum: .effectViaHuePendulum
        case .viaHueWave: .effectViaHueWave
        case .viaTypingHeatmap: .effectViaTypingHeatmap
        case .viaDigitalRain: .effectViaDigitalRain
        case .viaReactiveSimple: .effectViaReactiveSimple
        case .viaReactive: .effectViaReactive
        case .viaReactiveWide: .effectViaReactiveWide
        case .viaReactiveMultiwide: .effectViaReactiveMultiwide
        case .viaReactiveCross: .effectViaReactiveCross
        case .viaReactiveMulticross: .effectViaReactiveMulticross
        case .viaReactiveNexus: .effectViaReactiveNexus
        case .viaReactiveMultiNexus: .effectViaReactiveMultiNexus
        case .viaSplash: .effectViaSplash
        case .viaMultiSplash: .effectViaMultiSplash
        case .viaSolidSplash: .effectViaSolidSplash
        case .viaSolidMultiSplash: .effectViaSolidMultiSplash
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
