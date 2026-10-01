// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ResourceBench", platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "ResourceBench", targets: ["ResourceBench"])],
    targets: [.target(name: "ResourceBench", swiftSettings: [.define("RESOURCE_BENCH")]),
              .testTarget(name: "ResourceBenchTests", dependencies: ["ResourceBench"])])
