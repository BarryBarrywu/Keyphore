import XCTest
@testable import KeyphoreCore

@MainActor
final class ManagedUpdateAcceptanceTests: XCTestCase {
    func testAutomaticCheckWaitsForApprovalBeforeInstalling() async throws {
        let transport = RecordingUpdateTransport(candidate: makeCandidate())

        let decision = ManagedUpdatePolicy.evaluate(try await transport.check())

        XCTAssertEqual(
            decision,
            .accepted(
                hookDigest: HookDefinition.reviewedReleaseDigest,
                hookConsent: .reusable
            )
        )
        XCTAssertEqual(transport.installCount, 0)

        try await transport.install()

        XCTAssertEqual(transport.installCount, 1)
    }

    func testChangedHooksArePreparedBeforeInstallAndUnchangedHooksReuseConsent() {
        var prepareCount = 0
        var installCount = 0
        let gate = ManagedUpdateInstallationGate(
            prepareChangedHooks: { prepareCount += 1 },
            recoverChangedHooks: {}
        )

        XCTAssertFalse(gate.postponeIfNeeded(
            version: "0.2.0",
            hookDigest: HookDefinition.reviewedReleaseDigest,
            install: { installCount += 1 }
        ))
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(installCount, 0)

        XCTAssertTrue(gate.postponeIfNeeded(
            version: "0.2.0",
            hookDigest: "changed-hooks",
            install: { installCount += 1 }
        ))
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(gate.state, .prepared(version: "0.2.0"))
    }

    func testChangedHookPreparationFailurePostponesInstallAndCanRetry() {
        var prepareFailures = 1
        var prepareCount = 0
        var recoveryCount = 0
        var installCount = 0
        let gate = ManagedUpdateInstallationGate(
            prepareChangedHooks: {
                prepareCount += 1
                if prepareFailures > 0 {
                    prepareFailures -= 1
                    throw UpdateTransportError.failed
                }
            },
            recoverChangedHooks: { recoveryCount += 1 }
        )

        XCTAssertTrue(gate.postponeIfNeeded(
            version: "0.2.0",
            hookDigest: "changed-hooks",
            install: { installCount += 1 }
        ))
        XCTAssertEqual(gate.state, .postponed(version: "0.2.0"))
        XCTAssertEqual(installCount, 0)
        XCTAssertEqual(recoveryCount, 1)

        XCTAssertTrue(gate.retryPostponedInstall())
        XCTAssertEqual(gate.state, .prepared(version: "0.2.0"))
        XCTAssertEqual(prepareCount, 2)
        XCTAssertEqual(installCount, 1)
    }

    func testRecoveryFailureRemainsObservableAndCanBeRetried() throws {
        var recoveryFailures = 1
        let gate = ManagedUpdateInstallationGate(
            prepareChangedHooks: { throw UpdateTransportError.failed },
            recoverChangedHooks: {
                if recoveryFailures > 0 {
                    recoveryFailures -= 1
                    throw UpdateTransportError.failed
                }
            }
        )

        XCTAssertTrue(gate.postponeIfNeeded(
            version: "0.2.0",
            hookDigest: "changed-hooks",
            install: {}
        ))
        XCTAssertEqual(gate.state, .recoveryFailed(version: "0.2.0"))

        XCTAssertTrue(try gate.retryFailedRecovery())
        XCTAssertEqual(gate.state, .postponed(version: "0.2.0"))
    }

    func testInvalidUntrustedUnsupportedAndIncompleteCandidatesAreRejected() {
        let rejected: [(ManagedUpdateCandidate, ManagedUpdateRejection)] = [
            (makeCandidate(signingValidated: false), .invalidSignature),
            (makeCandidate(feedTrusted: false), .untrustedFeed),
            (makeCandidate(systemVersionSupported: false), .unsupportedPlatform),
            (makeCandidate(declaresArm64: false), .unsupportedPlatform),
            (makeCandidate(arm64HardwareSupported: false), .unsupportedPlatform),
            (makeCandidate(hookDefinitionsDigest: nil), .invalidMetadata),
        ]

        for (candidate, rejection) in rejected {
            XCTAssertEqual(
                ManagedUpdatePolicy.evaluate(candidate),
                .rejected(rejection)
            )
        }
    }

    func testFailedChangedHookInstallRestoresHooksPreservesProfileAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "keyphore-update-\(UUID().uuidString)")
        let profileURL = root.appending(path: "profile.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profileStore = LocalProfileStore(url: profileURL)
        try profileStore.save(.default)
        let profileBefore = try Data(contentsOf: profileURL)
        let actions = ActionLog()
        let transport = RecordingUpdateTransport(
            candidate: makeCandidate(hookDefinitionsDigest: "changed-hooks"),
            actions: actions,
            installFailures: 1
        )
        let gate = ManagedUpdateInstallationGate(
            prepareChangedHooks: { actions.values.append(.disableHooks) },
            recoverChangedHooks: { actions.values.append(.restoreHooks) }
        )
        let candidate = try await transport.check()
        guard case let .accepted(digest, _) = ManagedUpdatePolicy.evaluate(candidate) else {
            return XCTFail("Expected an accepted update")
        }

        XCTAssertTrue(gate.postponeIfNeeded(
            version: "0.2.0",
            hookDigest: digest,
            install: {}
        ))
        do {
            try await transport.install()
            XCTFail("Expected the controlled install to fail")
        } catch {
            try gate.recoverAfterAbort()
        }

        XCTAssertEqual(actions.values, [.disableHooks, .install, .restoreHooks])
        XCTAssertEqual(try Data(contentsOf: profileURL), profileBefore)

        XCTAssertTrue(gate.postponeIfNeeded(
            version: "0.2.0",
            hookDigest: digest,
            install: {}
        ))
        try await transport.install()

        XCTAssertEqual(transport.installCount, 2)
        XCTAssertEqual(gate.state, .prepared(version: "0.2.0"))
    }

    private func makeCandidate(
        signingValidated: Bool = true,
        feedTrusted: Bool = true,
        systemVersionSupported: Bool = true,
        declaresArm64: Bool = true,
        arm64HardwareSupported: Bool = true,
        hookDefinitionsDigest: String? = HookDefinition.reviewedReleaseDigest
    ) -> ManagedUpdateCandidate {
        ManagedUpdateCandidate(
            signingValidated: signingValidated,
            feedTrusted: feedTrusted,
            systemVersionSupported: systemVersionSupported,
            declaresArm64: declaresArm64,
            arm64HardwareSupported: arm64HardwareSupported,
            hookDefinitionsDigest: hookDefinitionsDigest
        )
    }
}

@MainActor
private final class RecordingUpdateTransport {
    let candidate: ManagedUpdateCandidate
    private(set) var installCount = 0
    private let actions: ActionLog?
    private var installFailures: Int

    init(
        candidate: ManagedUpdateCandidate,
        actions: ActionLog? = nil,
        installFailures: Int = 0
    ) {
        self.candidate = candidate
        self.actions = actions
        self.installFailures = installFailures
    }

    func check() async throws -> ManagedUpdateCandidate {
        candidate
    }

    func install() async throws {
        installCount += 1
        actions?.values.append(.install)
        if installFailures > 0 {
            installFailures -= 1
            throw UpdateTransportError.failed
        }
    }
}

private final class ActionLog {
    var values: [Action] = []
}

private enum Action: Equatable {
    case disableHooks
    case install
    case restoreHooks
}

private enum UpdateTransportError: Error {
    case failed
}
