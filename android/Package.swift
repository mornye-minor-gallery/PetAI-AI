// swift-tools-version: 6.4
import Foundation
import PackageDescription

guard let source = ProcessInfo.processInfo.environment["PETAI_LITERTLM_SOURCE_DIR"],
      let library = ProcessInfo.processInfo.environment["PETAI_LITERTLM_LIBRARY_DIR"] else {
    fatalError("Set PETAI_LITERTLM_SOURCE_DIR and PETAI_LITERTLM_LIBRARY_DIR.")
}
let package = Package(
    name: "PetAIAndroid",
    products: [
        .library(name: "PetAIAndroid", type: .dynamic, targets: ["AndroidChatBridge"]),
        .library(name: "AndroidChatBridge", targets: ["AndroidChatBridge"]),
        .library(name: "CAndroidDispatch", targets: ["CAndroidDispatch"]),
    ],
    dependencies: [.package(path: "../ios")],
    targets: [
        .target(name: "CAndroidDispatch", path: "Dispatch", publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("android")]),
        .target(name: "AndroidChatBridge",
                dependencies: ["CAndroidDispatch", .product(name: "PetAIChatRuntime", package: "ios")],
                path: "Runtime",
                swiftSettings: [.unsafeFlags(["-Xcc", "-I" + source])],
                linkerSettings: [.unsafeFlags(["-L", library, "-llitert-lm"])]),
    ])
