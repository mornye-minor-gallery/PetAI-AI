// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "ProductPromptAdapter",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "ProductAdapterCore", targets: ["ProductAdapterCore"]),
        .executable(name: "product-prompt-adapter", targets: ["ProductPromptAdapter"]),
    ],
    dependencies: [
        .package(path: "../../../../ios/EdgeLLM"),
    ],
    targets: [
        .target(
            name: "ProductAdapterCore",
            dependencies: [.product(name: "EdgeLLM", package: "EdgeLLM")]
        ),
        .executableTarget(
            name: "ProductPromptAdapter",
            dependencies: ["ProductAdapterCore"]
        ),
        .testTarget(
            name: "ProductAdapterCoreTests",
            dependencies: ["ProductAdapterCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
