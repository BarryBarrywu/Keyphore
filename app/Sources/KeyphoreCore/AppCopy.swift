import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-hans"
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
    case keyboardConnected = "keyboard.connected"
    case keyboardAmbiguous = "keyboard.ambiguous"
    case protocolHealthy = "keyboard.protocol_healthy"
    case settings = "action.settings"
    case diagnostics = "action.diagnostics"
    case quit = "action.quit"
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
}

public enum AppCopy {
    public static func value(_ key: AppCopyKey) -> String {
        String(
            localized: String.LocalizationValue(key.rawValue),
            bundle: .module
        )
    }

    public static func value(_ key: AppCopyKey, language: AppLanguage) -> String {
        guard
            let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return key.rawValue
        }

        return bundle.localizedString(forKey: key.rawValue, value: key.rawValue, table: nil)
    }
}
