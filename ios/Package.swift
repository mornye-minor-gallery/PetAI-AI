// swift-tools-version: 6.4
import Foundation
import PackageDescription

let android = ProcessInfo.processInfo.environment["PETAI_ANDROID_CORE_POC"] == "1"
let nativeSource = ProcessInfo.processInfo.environment["PETAI_LITERTLM_SOURCE_DIR"] ?? ""
let nativeLibrary = ProcessInfo.processInfo.environment["PETAI_LITERTLM_LIBRARY_DIR"] ?? ""
let external = nativeSource + "/bazel-" + URL(fileURLWithPath: nativeSource).lastPathComponent + "/external"

let package = Package(
    name: "PetAIChatRuntime",
    platforms: [.iOS(.v15)],
    products: [.library(name: "PetAIChatRuntime", targets: ["PetAIChatRuntime"])],
    dependencies: [
        .package(path: "EdgeLLM"),
        .package(path: "ThirdParty/LiteRTLM"),
    ] + (android ? [] : [.package(path: "ThirdParty/EmbeddingGemmaNative")]),
    targets: (android ? [
        .target(name: "CEmbeddingGemma",
                path: "ThirdParty/EmbeddingGemmaNative/Sources/CEmbeddingGemma",
                publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-I" + external + "/litert", "-I" + external + "/sentencepiece",
                    "-I" + external + "/com_google_absl",
                    "-I" + nativeSource + "/bazel-out/arm64-v8a-opt/bin/external/litert"])],
                linkerSettings: [.unsafeFlags(["-L" + nativeLibrary, "-llitert-lm"])]),
    ] : []) + [
        .target(name: "PetAIChatRuntime",
                dependencies: [
                    .product(name: "EdgeLLM", package: "EdgeLLM"),
                    .product(name: "LiteRTLM", package: "LiteRTLM"),
                ] + (android ? [.target(name: "CEmbeddingGemma")] :
                    [.product(name: "EmbeddingGemmaNative", package: "EmbeddingGemmaNative")]),
                path: "EdgeLLMLab/EdgeLLMLab",
                exclude: ["Benchmark", "ContentView.swift", "EdgeLLMLabApp.swift", "Info.plist",
                          "Assets.xcassets", "Embedding/EmbeddingAssetStore.swift", "Embedding/EmbeddingTestView.swift"],
                sources: ["Runtime", "Memory", "Embedding/EmbeddingGemmaEmbedder.swift",
                          "Embedding/AndroidEmbeddingRunner.swift"],
                swiftSettings: android ? [.unsafeFlags(["-Xcc", "-I" + nativeSource])] : []),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx20
)
