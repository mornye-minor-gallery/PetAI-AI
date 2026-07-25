// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EmbeddingGemmaNative",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "EmbeddingGemmaNative",
            targets: ["EmbeddingGemmaNative"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "CLiteRT",
            path: "../../.artifacts/CLiteRT.xcframework.zip"
        ),
        .binaryTarget(
            name: "CSentencePiece",
            path: "../../.artifacts/CSentencePiece.xcframework"
        ),
        .target(
            name: "EmbeddingGemmaNative",
            dependencies: [
                "CLiteRT",
                "CSentencePiece",
            ],
            path: "Sources/EmbeddingGemmaNative",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
