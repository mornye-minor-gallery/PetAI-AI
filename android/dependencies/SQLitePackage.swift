// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "AndroidSQLite",
    products: [.library(name: "SQLite3", targets: ["SQLite3"])],
    targets: [
        .target(name: "SQLite3", publicHeadersPath: "include",
                cSettings: [.define("SQLITE_THREADSAFE", to: "1")],
                linkerSettings: [.linkedLibrary("m"), .linkedLibrary("dl")])
    ]
)
