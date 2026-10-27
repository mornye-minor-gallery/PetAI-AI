// swift-tools-version: 6.4
import Foundation
import PackageDescription

guard let source = ProcessInfo.processInfo.environment["PETAI_LITERTLM_SOURCE_DIR"],
      let library = ProcessInfo.processInfo.environment["PETAI_LITERTLM_LIBRARY_DIR"] else {
    fatalError("Set PETAI_LITERTLM_SOURCE_DIR and PETAI_LITERTLM_LIBRARY_DIR.")
}
let backend = ProcessInfo.processInfo.environment["PETAI_ANDROID_LLM_BACKEND"] ?? "cpu"
guard ["cpu", "gpu"].contains(backend) else { fatalError("PETAI_ANDROID_LLM_BACKEND must be cpu or gpu") }
let package = Package(
    name: "PetAIAndroid",
    products: [
        .library(name: "PetAIAndroid", type: .dynamic, targets: ["AndroidChatBridge"]),
        .library(name: "AndroidChatBridge", targets: ["AndroidChatBridge"]),
        .library(name: "CAndroidDispatch", targets: ["CAndroidDispatch"]),
        .library(name: "PetAIPlatformProbe", type: .dynamic, targets: ["AndroidPlatformProbe"]),
    ],
    dependencies: [.package(path: "../ios"), .package(path: "../ios/EdgeLLM")],
    targets: [
        .target(name: "CAndroidDispatch", path: "Dispatch", publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("android"), .linkedLibrary("log")]),
        .target(name: "CAndroidPlatformJNI", path: "PlatformJNI", publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("log")]),
        .target(name: "AndroidPlatformTools",
                dependencies: ["CAndroidPlatformJNI", .product(name: "EdgeLLM", package: "EdgeLLM")], path: "PlatformSwift"),
        // Separate development product: these test entry points cannot enter PetAIAndroid.
        .target(name: "CAndroidPlatformProbe", path: "tests/OwnedAlarms/ProbeJNI", publicHeadersPath: "include"),
        .target(name: "AndroidPlatformProbe", dependencies: ["AndroidPlatformTools", "CAndroidDispatch", "CAndroidPlatformProbe",
                .product(name: "EdgeLLM", package: "EdgeLLM")], path: "tests/OwnedAlarms/ProbeSwift"),
        .target(name: "AndroidChatBridge",
                dependencies: ["CAndroidDispatch", "AndroidPlatformTools", .product(name: "PetAIChatRuntime", package: "ios")],
                path: "Runtime",
                swiftSettings: [.unsafeFlags(["-Xcc", "-I" + source])],
                linkerSettings: [.unsafeFlags(["-L", library, "-llitert-lm"])]),
    ])
