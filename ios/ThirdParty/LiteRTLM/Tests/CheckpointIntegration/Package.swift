// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "CheckpointIntegration", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "EdgeLLM")], targets: [
        .systemLibrary(name: "CLiteRTLM", path: "CLiteRTLM"),
        .target(name: "LiteRTLM", dependencies: ["CLiteRTLM"], path: "LiteRTLM", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "Fixtures", dependencies: ["EdgeLLM"], path: "Fixtures"),
        .executableTarget(name: "Worker", dependencies: ["LiteRTLM", "Fixtures", "EdgeLLM"], path: "Worker")
    ])
