import Foundation

public struct NuPhyLightingProfile: Equatable, Sendable {
    public let revision: Int
    public let stateAddress: UInt16
    public let stateLength: Int
    public let mainAddress: UInt16
    public let mainLength: Int
    public let protectedRange: Range<Int>
    public let brightnessMirrorAddress: UInt16?

    private init(brightnessMirrorAddress: UInt16?) {
        revision = 1
        stateAddress = 0
        stateLength = 17
        mainAddress = 0
        mainLength = 9
        protectedRange = 9..<17
        self.brightnessMirrorAddress = brightnessMirrorAddress
    }

    public static let air65V3 = Self(brightnessMirrorAddress: 1)
    // Air75 readback showed a second brightness write scales RGB a second time.
    public static let air75V3 = Self(brightnessMirrorAddress: nil)

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
