import Foundation

public enum ManagedRemovalComponent: String, CaseIterable, Hashable, Sendable {
    case plugin
    case hooks
    case companion
    case backgroundRegistration
    case localProfile
    case managedRuntimeState
}

public enum ManagedRemovalStatus: Equatable, Sendable {
    case reviewRequired
    case repairRequired
    case completed
}

public struct ManagedRemovalSnapshot: Equatable, Sendable {
    public let status: ManagedRemovalStatus
    public let components: Set<ManagedRemovalComponent>

    public init(
        status: ManagedRemovalStatus,
        components: Set<ManagedRemovalComponent> = Set(ManagedRemovalComponent.allCases)
    ) {
        self.status = status
        self.components = components
    }
}

public enum ManagedRemovalError: Error, Equatable, Sendable {
    case incomplete
}

public protocol ManagedRemovalIntegrating: AnyObject {
    func inspectManagedRemoval() throws -> ManagedRemovalStatus
    func beginManagedRemoval() throws
    func requestSignalOffForRemoval() throws
    func disableOwnedHooksForRemoval() throws
    func removeCompanionAndBackgroundRegistration() throws
    func removePluginAndHooks() throws
    func removeLocalProfileAndManagedRuntimeState() throws
    func verifyManagedRemoval() throws -> Bool
    func completeManagedRemoval() throws
}

public final class ManagedRemoval: @unchecked Sendable {
    private let integration: any ManagedRemovalIntegrating

    public init(integration: any ManagedRemovalIntegrating) {
        self.integration = integration
    }

    public func inspect() throws -> ManagedRemovalSnapshot {
        ManagedRemovalSnapshot(status: try integration.inspectManagedRemoval())
    }

    public func removeAfterConfirmation() throws -> ManagedRemovalSnapshot {
        try integration.beginManagedRemoval()
        try integration.requestSignalOffForRemoval()
        try integration.disableOwnedHooksForRemoval()
        try integration.removeCompanionAndBackgroundRegistration()
        try integration.removePluginAndHooks()
        try integration.removeLocalProfileAndManagedRuntimeState()
        guard try integration.verifyManagedRemoval() else {
            throw ManagedRemovalError.incomplete
        }
        try integration.completeManagedRemoval()
        return ManagedRemovalSnapshot(status: .completed)
    }
}
