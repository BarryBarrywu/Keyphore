// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KeyphoreAppModules",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KeyphoreCore", targets: ["KeyphoreCore"]),
    ],
    targets: [
        .target(
            name: "KeyphoreCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "KeyphoreCoreTests",
            dependencies: ["KeyphoreCore"]
        ),
    ]
)
