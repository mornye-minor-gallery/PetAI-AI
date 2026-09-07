// swift-tools-version: 6.3
import PackageDescription

// The evaluation executable is separate from the app and its release targets.
let package = Package(
    name: "BeolmuriEvalWorker",
    platforms: [.macOS(.v12)],
    dependencies: [.package(path: "../../../ios/EdgeLLM")],
    targets: [.executableTarget(
        name: "beolmuri-swift-worker",
        dependencies: [.product(name: "EdgeLLM", package: "EdgeLLM")]
    )]
)
