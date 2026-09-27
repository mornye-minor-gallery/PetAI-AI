// swift-tools-version: 5.9

import PackageDescription
import Foundation

let android = ProcessInfo.processInfo.environment["PETAI_ANDROID_CORE_POC"] == "1"
let source = ProcessInfo.processInfo.environment["PETAI_LITERTLM_SOURCE_DIR"] ?? ""
let library = ProcessInfo.processInfo.environment["PETAI_LITERTLM_LIBRARY_DIR"] ?? ""
if android && (source.isEmpty || library.isEmpty) {
    fatalError("Android LiteRT-LM requires the pinned native source and library directories.")
}

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
        android ? .systemLibrary(name: "CLiteRTLM", path: "Sources/CLiteRTLM") : .binaryTarget(
            name: "CLiteRTLM",
            path: "Artifacts/CLiteRTLM.xcframework"
        ),
        .target(
            name: "LiteRTLM",
            dependencies: ["CLiteRTLM"],
            path: "Sources/LiteRTLM",
            swiftSettings: android ? [.unsafeFlags(["-Xcc", "-I" + source])] : [],
            linkerSettings: [
                .unsafeFlags(android ? ["-L", library, "-llitert-lm", "-llog"] : ["-Xlinker", "-all_load"]),
            ]
        ),
    ]
)
