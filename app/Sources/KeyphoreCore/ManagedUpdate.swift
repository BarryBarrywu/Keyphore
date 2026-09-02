public struct ManagedUpdateCandidate: Equatable, Sendable {
    public let signingValidated: Bool
    public let feedTrusted: Bool
    public let systemVersionSupported: Bool
    public let declaresArm64: Bool
    public let arm64HardwareSupported: Bool
    public let hookDefinitionsDigest: String?

    public init(
        signingValidated: Bool,
        feedTrusted: Bool,
        systemVersionSupported: Bool,
        declaresArm64: Bool,
        arm64HardwareSupported: Bool,
        hookDefinitionsDigest: String?
    ) {
        self.signingValidated = signingValidated
        self.feedTrusted = feedTrusted
        self.systemVersionSupported = systemVersionSupported
        self.declaresArm64 = declaresArm64
        self.arm64HardwareSupported = arm64HardwareSupported
        self.hookDefinitionsDigest = hookDefinitionsDigest
    }
}

public enum ManagedUpdateHookConsent: Equatable, Sendable {
    case reusable
    case required

    public static func forDigest(_ digest: String) -> Self {
        digest == HookDefinition.reviewedReleaseDigest ? .reusable : .required
    }
}

public enum ManagedUpdateRejection: Equatable, Sendable {
    case invalidSignature
    case untrustedFeed
    case unsupportedPlatform
    case invalidMetadata
}

public enum ManagedUpdateDecision: Equatable, Sendable {
    case accepted(hookDigest: String, hookConsent: ManagedUpdateHookConsent)
    case rejected(ManagedUpdateRejection)
}

public enum ManagedUpdatePolicy {
    public static func evaluate(_ candidate: ManagedUpdateCandidate) -> ManagedUpdateDecision {
        guard candidate.feedTrusted else { return .rejected(.untrustedFeed) }
        guard candidate.signingValidated else { return .rejected(.invalidSignature) }
        guard candidate.systemVersionSupported,
              candidate.declaresArm64,
              candidate.arm64HardwareSupported else {
            return .rejected(.unsupportedPlatform)
        }
        guard let digest = candidate.hookDefinitionsDigest, !digest.isEmpty else {
            return .rejected(.invalidMetadata)
        }
        return .accepted(
            hookDigest: digest,
            hookConsent: ManagedUpdateHookConsent.forDigest(digest)
        )
    }
}

public enum ManagedUpdateInstallationState: Equatable, Sendable {
    case idle
    case postponed(version: String)
    case prepared(version: String)
    case recoveryFailed(version: String)
}

@MainActor
public final class ManagedUpdateInstallationGate {
    public private(set) var state: ManagedUpdateInstallationState = .idle

    private let prepareChangedHooks: () throws -> Void
    private let recoverChangedHooks: () throws -> Void
    private var postponedInstall: (version: String, handler: () -> Void)?
    private var recoveryDestination: ManagedUpdateInstallationState?

    public init(
        prepareChangedHooks: @escaping () throws -> Void,
        recoverChangedHooks: @escaping () throws -> Void
    ) {
        self.prepareChangedHooks = prepareChangedHooks
        self.recoverChangedHooks = recoverChangedHooks
    }

    public func postponeIfNeeded(
        version: String,
        hookDigest: String,
        install: @escaping () -> Void
    ) -> Bool {
        guard ManagedUpdateHookConsent.forDigest(hookDigest) == .required else {
            return false
        }
        do {
            try prepareChangedHooks()
            state = .prepared(version: version)
            install()
        } catch {
            postponedInstall = (version, install)
            recover(to: .postponed(version: version))
        }
        return true
    }

    public func retryPostponedInstall() -> Bool {
        guard case .postponed = state, let postponedInstall else { return false }
        do {
            try prepareChangedHooks()
            self.postponedInstall = nil
            state = .prepared(version: postponedInstall.version)
            postponedInstall.handler()
        } catch {
            recover(to: .postponed(version: postponedInstall.version))
        }
        return true
    }

    public func recoverAfterAbort() throws {
        guard case let .prepared(version) = state else { return }
        do {
            try recoverChangedHooks()
            state = .idle
        } catch {
            recoveryDestination = .idle
            state = .recoveryFailed(version: version)
            throw error
        }
    }

    public func retryFailedRecovery() throws -> Bool {
        guard case .recoveryFailed = state, let recoveryDestination else { return false }
        try recoverChangedHooks()
        self.recoveryDestination = nil
        state = recoveryDestination
        return true
    }

    private func recover(to destination: ManagedUpdateInstallationState) {
        do {
            try recoverChangedHooks()
            state = destination
        } catch {
            recoveryDestination = destination
            let version: String
            switch destination {
            case let .postponed(value), let .prepared(value), let .recoveryFailed(value):
                version = value
            case .idle:
                return
            }
            state = .recoveryFailed(version: version)
        }
    }
}
