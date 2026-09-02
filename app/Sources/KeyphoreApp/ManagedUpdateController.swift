import AppKit
import KeyphoreCore
import Sparkle

@MainActor
final class ManagedUpdateController {
    private let updaterController: SPUStandardUpdaterController?
    private let delegate: ManagedUpdateDelegate

    init(
        bundle: Bundle = .main,
        prepareChangedHooks: @escaping () throws -> Void,
        recoverChangedHooks: @escaping () throws -> Void,
        presentError: @escaping (String) -> Void
    ) {
        let feedTrusted = Self.hasSignedFeedConfiguration(bundle: bundle)
        delegate = ManagedUpdateDelegate(
            feedTrusted: feedTrusted,
            prepareChangedHooks: prepareChangedHooks,
            recoverChangedHooks: recoverChangedHooks,
            presentError: presentError
        )
        guard feedTrusted else {
            updaterController = nil
            return
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
    }

    func start() {
        updaterController?.startUpdater()
    }

    func checkForUpdates() {
        if delegate.retryFailedRecovery() {
            return
        }
        if delegate.retryPostponedInstall() {
            return
        }
        guard let updaterController else {
            presentChannelUnavailable()
            return
        }
        updaterController.checkForUpdates(nil)
    }

    private func presentChannelUnavailable() {
        let alert = NSAlert()
        alert.messageText = AppCopy.value(.productName)
        alert.informativeText = AppCopy.value(.updateChannelUnavailable)
        alert.runModal()
    }

    private static func hasSignedFeedConfiguration(bundle: Bundle) -> Bool {
        guard
            let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let url = URL(string: feed),
            url.scheme == "https",
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            Data(base64Encoded: publicKey)?.count == 32
        else {
            return false
        }
        return true
    }
}

@MainActor
private final class ManagedUpdateDelegate: NSObject, SPUUpdaterDelegate {
    private let feedTrusted: Bool
    private let presentError: (String) -> Void
    private let installationGate: ManagedUpdateInstallationGate
    private var hookDigests: [String: String] = [:]

    init(
        feedTrusted: Bool,
        prepareChangedHooks: @escaping () throws -> Void,
        recoverChangedHooks: @escaping () throws -> Void,
        presentError: @escaping (String) -> Void
    ) {
        self.feedTrusted = feedTrusted
        self.presentError = presentError
        installationGate = ManagedUpdateInstallationGate(
            prepareChangedHooks: prepareChangedHooks,
            recoverChangedHooks: recoverChangedHooks
        )
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate item: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        let decision = ManagedUpdatePolicy.evaluate(ManagedUpdateCandidate(
            signingValidated: item.signingValidationStatus == .succeeded,
            feedTrusted: feedTrusted,
            systemVersionSupported: item.minimumOperatingSystemVersionIsOK,
            declaresArm64: item.hardwareRequirements.contains("arm64"),
            arm64HardwareSupported: item.arm64HardwareRequirementIsOK,
            hookDefinitionsDigest: hookDigest(in: item)
        ))
        switch decision {
        case let .accepted(digest, _):
            hookDigests[item.versionString] = digest
        case let .rejected(rejection):
            throw NSError(
                domain: "com.barrywu.keyphore.update",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: rejection.message]
            )
        }
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let digest = hookDigests[item.versionString] else { return false }
        let stateBefore = installationGate.state
        let postponed = installationGate.postponeIfNeeded(
            version: item.versionString,
            hookDigest: digest,
            install: installHandler
        )
        if postponed, stateBefore != installationGate.state {
            presentPreparationStateErrorIfNeeded()
        }
        return postponed
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        do {
            try installationGate.recoverAfterAbort()
        } catch {
            presentError(AppCopy.value(.updateHookRecoveryFailed))
        }
    }

    func retryFailedRecovery() -> Bool {
        do {
            return try installationGate.retryFailedRecovery()
        } catch {
            presentError(AppCopy.value(.updateHookRecoveryFailed))
            return true
        }
    }

    func retryPostponedInstall() -> Bool {
        let retried = installationGate.retryPostponedInstall()
        if retried {
            presentPreparationStateErrorIfNeeded()
        }
        return retried
    }

    private func presentPreparationStateErrorIfNeeded() {
        switch installationGate.state {
        case .postponed:
            presentError(AppCopy.value(.updateHookPreparationFailed))
        case .recoveryFailed:
            presentError(AppCopy.value(.updateHookRecoveryFailed))
        case .idle, .prepared:
            break
        }
    }

    private func hookDigest(in item: SUAppcastItem) -> String? {
        for key in ["keyphore:hookDefinitionsDigest", "hookDefinitionsDigest"] {
            if let digest = item.propertiesDictionary[key] as? String, !digest.isEmpty {
                return digest
            }
        }
        return nil
    }
}

private extension ManagedUpdateRejection {
    var message: String {
        switch self {
        case .invalidMetadata:
            AppCopy.value(.updateInvalidMetadata)
        case .unsupportedPlatform:
            AppCopy.value(.updateUnsupported)
        case .invalidSignature, .untrustedFeed:
            AppCopy.value(.updateUntrusted)
        }
    }
}
