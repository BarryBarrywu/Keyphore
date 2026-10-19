import Foundation

public struct NuPhyLightingProfile: Equatable, Sendable {
    public let revision: Int
    public let stateAddress: UInt16
    public let stateLength: Int
    public let mainAddress: UInt16
    public let mainLength: Int
    public let protectedRange: Range<Int>
    public let model: SupportedKeyboardModel

    private init(model: SupportedKeyboardModel) {
        revision = 2
        stateAddress = 0
        stateLength = 17
        mainAddress = 0
        mainLength = 9
        protectedRange = 9..<17
        self.model = model
    }

    public static let air65V3 = Self(model: .air65V3)
    public static let air75V3 = Self(model: .air75V3)

    public func range(for zone: LightingZone) -> Range<Int> { zone == .backlight ? 0..<9 : 9..<17 }

    public static func verified(for model: SupportedKeyboardModel) -> Self? {
        switch model {
        case .air65V3: .air65V3
        case .air75V3: .air75V3
        default: nil
        }
    }

    public static func experimental(for model: CandidateKeyboardModel) -> Self? {
        // NuPhyIO layout/capability metadata does not establish lighting packet compatibility.
        // Add a model only with its own packet evidence and protected-zone definition.
        nil
    }
}
