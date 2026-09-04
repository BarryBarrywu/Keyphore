import Foundation

public struct CandidateKeyboardKey: Decodable, Equatable, Sendable {
    public enum Shape: String, Decodable, Sendable { case key, isoEnter, knob }
    public let label: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let shape: Shape
    public let accent: Bool
}

public struct CandidateKeyboardDefinition: Decodable, Sendable {
    public let name: String
    public let sourceModel: String
    public let productID: UInt16
    public let keys: [CandidateKeyboardKey]

    public var width: Double { keys.map { $0.x + $0.width }.max() ?? 0 }
    public var height: Double { keys.map { $0.y + $0.height }.max() ?? 0 }
    public var aspectRatio: Double { (width + 1.2) / (height + 1.2) }
}

public enum CandidateKeyboardCatalog {
    private struct Resource: Decodable {
        let source: String
        let models: [CandidateKeyboardDefinition]
    }

    // Bundled model identities and physical layouts from NuPhyIO 2.2.6, never a control allowlist.
    private static let resource: Resource = {
        let url = Bundle.module.url(forResource: "candidate-keyboards", withExtension: "json")!
        return try! JSONDecoder().decode(Resource.self, from: Data(contentsOf: url))
    }()

    public static let definitions = resource.models
    public static let source = resource.source
    static let modelsByProductID: [UInt16: CandidateKeyboardModel] = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.productID, CandidateKeyboardModel(rawValue: $0.name)!) }
    )
}
