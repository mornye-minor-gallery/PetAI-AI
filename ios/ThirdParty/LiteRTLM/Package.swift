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
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.14.0/CLiteRTLM.xcframework.zip",
            checksum: "dddac2f6713ed65eaf01c18e115d9fec22184adf575cc7856a21387e8ba937e1"
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
