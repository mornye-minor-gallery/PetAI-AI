// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let androidPoc = ProcessInfo.processInfo.environment["PETAI_ANDROID_CORE_POC"] == "1"

let package = Package(
    name: "EdgeLLM",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "EdgeLLM",
            targets: ["EdgeLLM"]
        ),
    ],
    dependencies: androidPoc ? [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
        .package(path: "../../android/.artifacts/sqlite-package"),
    ] : [],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "EdgeLLM",
            dependencies: androidPoc ? [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.android])),
                .product(name: "SQLite3", package: "sqlite-package", condition: .when(platforms: [.android])),
            ] : [],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "EdgeLLMTests",
            dependencies: ["EdgeLLM"],
            resources: [.process("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
