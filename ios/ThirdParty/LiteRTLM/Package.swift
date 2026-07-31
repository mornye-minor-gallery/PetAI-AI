// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LiteRTLMVendor",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "LiteRTLM",
            targets: ["LiteRTLM"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM",
            path: "Artifacts/CLiteRTLM.xcframework"
        ),
        .target(
            name: "LiteRTLM",
            dependencies: ["CLiteRTLM"],
            path: "Sources/LiteRTLM",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-all_load"]),
            ]
        ),
    ]
)
