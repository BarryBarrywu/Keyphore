import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}

public enum AppCopyKey: String, CaseIterable, Sendable {
    case productName = "product.name"
    case deviceName = "device.name"
    case currentSignal = "status.current_signal"
    case keyboardHealth = "status.keyboard_health"
    case configurationRequired = "state.configuration_required"
    case configured = "state.configured"
    case ready = "state.ready"
    case signalOff = "signal.off"
    case execution = "signal.execution"
    case attention = "signal.attention"
    case completion = "signal.completion"
    case keyboardDisconnected = "keyboard.disconnected"
    case keyboardUnavailable = "keyboard.unavailable"
    case keyboardConnected = "keyboard.connected"
    case keyboardAmbiguous = "keyboard.ambiguous"
    case protocolHealthy = "keyboard.protocol_healthy"
    case settings = "action.settings"
    case diagnostics = "action.diagnostics"
    case quit = "action.quit"
    case checkForUpdates = "update.check"
    case updateInvalidMetadata = "update.invalid_metadata"
    case updateUnsupported = "update.unsupported"
    case updateUntrusted = "update.untrusted"
    case updateHookPreparationFailed = "update.hook_preparation_failed"
    case updateHookRecoveryFailed = "update.hook_recovery_failed"
    case updateChannelUnavailable = "update.channel_unavailable"
    case rhythmLightUnchanged = "keyboard.rhythm_light_unchanged"
    case setupTitle = "setup.title"
    case setupHostFound = "setup.host_found"
    case setupDesktopHost = "setup.host.desktop"
    case setupCommandLineHost = "setup.host.command_line"
    case setupHostMissing = "setup.host_missing"
    case setupHookReview = "setup.hook_review"
    case setupPrivacy = "setup.privacy"
    case setupFields = "setup.fields"
    case setupCommand = "setup.command"
    case setupTimeout = "setup.timeout"
    case setupHash = "setup.hash"
    case setupConsent = "setup.consent"
    case setupWorking = "setup.working"
    case setupRepair = "setup.repair"
    case setupError = "setup.error"
    case setupHooksChanged = "setup.hooks_changed"
    case setupConfigured = "setup.configured"
    case setupWaitingForKeyboard = "setup.waiting_for_keyboard"
    case setupLoginLaunch = "setup.login_launch"
    case migrationTitle = "migration.title"
    case migrationDescription = "migration.description"
    case migrationConfirm = "migration.confirm"
    case migrationFreshConsent = "migration.fresh_consent"
    case migrationRepairTitle = "migration.repair_title"
    case migrationRepairDescription = "migration.repair_description"
    case migrationRepairAction = "migration.repair_action"
    case migrationError = "migration.error"
    case migrationComponentPlugin = "migration.component.plugin"
    case migrationComponentHooks = "migration.component.hooks"
    case migrationComponentCompanion = "migration.component.companion"
    case migrationComponentRuntimeState = "migration.component.runtime_state"
    case migrationPreviewRequired = "migration.preview_required"
    case migrationPreviewDescription = "migration.preview_description"
    case migrationPreviewAction = "migration.preview_action"
    case settingsLoginLaunch = "settings.login_launch"
    case quitError = "quit.error"
    case settingsVisibility = "settings.visibility"
    case settingsColor = "settings.color"
    case settingsBrightness = "settings.brightness"
    case settingsPattern = "settings.pattern"
    case settingsSteady = "settings.pattern.steady"
    case settingsSlowFlashing = "settings.pattern.slow_flashing"
    case settingsCompletionDuration = "settings.completion_duration"
    case settingsSeconds = "settings.seconds"
    case settingsSaveError = "settings.save_error"
    case settingsValidationError = "settings.validation_error"
    case previewTitle = "preview.title"
    case previewStart = "preview.start"
    case previewUnavailable = "preview.unavailable"
    case previewRunning = "preview.running"
    case previewProtocolVerified = "preview.protocol_verified"
    case previewRhythmPreserved = "preview.rhythm_preserved"
    case previewConfirmPrompt = "preview.confirm_prompt"
    case previewConfirm = "preview.confirm"
    case previewReject = "preview.reject"
    case previewConfirmed = "preview.confirmed"
    case previewRejected = "preview.rejected"
    case previewFailed = "preview.failed"
    case previewStateError = "preview.state_error"
    case removalTitle = "removal.title"
    case removalDescription = "removal.description"
    case removalAction = "removal.action"
    case removalConfirm = "removal.confirm"
    case removalRepairTitle = "removal.repair_title"
    case removalRepairDescription = "removal.repair_description"
    case removalWorking = "removal.working"
    case removalFailed = "removal.failed"
    case removalCompleted = "removal.completed"
    case removalTrashInstructions = "removal.trash_instructions"
    case removalFinish = "removal.finish"
    case removalComponentPlugin = "removal.component.plugin"
    case removalComponentHooks = "removal.component.hooks"
    case removalComponentCompanion = "removal.component.companion"
    case removalComponentBackgroundRegistration = "removal.component.background_registration"
    case removalComponentLocalProfile = "removal.component.local_profile"
    case removalComponentManagedRuntimeState = "removal.component.managed_runtime_state"
    case diagnosticFieldAppVersion = "diagnostic.field.app_version"
    case diagnosticFieldMacOS = "diagnostic.field.macos"
    case diagnosticFieldCodexHost = "diagnostic.field.codex_host"
    case diagnosticFieldHook = "diagnostic.field.hook"
    case diagnosticFieldCompanion = "diagnostic.field.companion"
    case diagnosticFieldKeyboard = "diagnostic.field.keyboard"
    case diagnosticFieldProtocol = "diagnostic.field.protocol"
    case diagnosticFieldErrorHealth = "diagnostic.field.error_health"
    case diagnosticHostBoth = "diagnostic.value.host_both"
    case diagnosticTrusted = "diagnostic.value.trusted"
    case diagnosticUntrusted = "diagnostic.value.untrusted"
    case diagnosticRunning = "diagnostic.value.running"
    case diagnosticNotRunning = "diagnostic.value.not_running"
    case diagnosticConnected = "diagnostic.value.connected"
    case diagnosticDisconnected = "diagnostic.value.disconnected"
    case diagnosticAmbiguous = "diagnostic.value.ambiguous"
    case diagnosticUnavailable = "diagnostic.value.unavailable"
    case diagnosticHealthy = "diagnostic.value.healthy"
    case diagnosticFailed = "diagnostic.value.failed"
    case diagnosticNotAvailable = "diagnostic.value.not_available"
    case diagnosticNotInstalled = "diagnostic.value.not_installed"
    case diagnosticNoErrors = "diagnostic.error.none"
    case diagnosticHealthUnavailable = "diagnostic.error.health_unavailable"
    case diagnosticIssueHookMissing = "diagnostic.error.hook_missing"
    case diagnosticIssueHookConsent = "diagnostic.error.hook_consent"
    case diagnosticIssueCompanion = "diagnostic.error.companion"
    case diagnosticIssueManagedState = "diagnostic.error.managed_state"
    case diagnosticIssueDisconnected = "diagnostic.error.disconnected"
    case diagnosticIssueKeyboardUnavailable = "diagnostic.error.keyboard_unavailable"
    case diagnosticIssueAmbiguous = "diagnostic.error.ambiguous"
    case diagnosticIssueProtocol = "diagnostic.error.protocol"
    case diagnosticActionConfigure = "diagnostic.action.configure"
    case diagnosticActionReviewHooks = "diagnostic.action.review_hooks"
    case diagnosticActionRepair = "diagnostic.action.repair"
    case diagnosticActionConnectKeyboard = "diagnostic.action.connect_keyboard"
    case diagnosticActionOneKeyboard = "diagnostic.action.one_keyboard"
    case diagnosticActionProtocol = "diagnostic.action.protocol"
    case diagnosticActionInstallCodex = "diagnostic.action.install_codex"
    case diagnosticPrivacyNotice = "diagnostic.privacy_notice"
    case diagnosticCollecting = "diagnostic.collecting"
    case diagnosticSave = "diagnostic.save"
    case diagnosticSaveFailed = "diagnostic.save_failed"
}

public enum AppCopy {
    public static func value(_ key: AppCopyKey) -> String {
        String(
            localized: String.LocalizationValue(key.rawValue),
            bundle: .module
        )
    }

    public static func value(_ key: AppCopyKey, language: AppLanguage) -> String {
        value(key, language: language, resources: .module)
    }

    static func value(
        _ key: AppCopyKey,
        language: AppLanguage,
        resources: Bundle
    ) -> String {
        let resourceNames = [language.rawValue, language.rawValue.lowercased()]
        guard let path = resourceNames.lazy.compactMap({ resource in
            resources.path(forResource: resource, ofType: "lproj")
        }).first,
            let bundle = Bundle(path: path)
        else {
            return key.rawValue
        }

        return bundle.localizedString(forKey: key.rawValue, value: key.rawValue, table: nil)
    }
}

public extension CodexSignal {
    var copyKey: AppCopyKey {
        switch self {
        case .execution: .execution
        case .attention: .attention
        case .completion: .completion
        }
    }
}
