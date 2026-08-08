// swift-tools-version: 6.0
import PackageDescription

// A throwaway executable that writes a demo SwiftData store for the screenshot
// harness. It depends on CheerioKit by path so the store it writes is the same
// schema the app opens — a hand-rolled store would drift the moment a model
// gained a property.
let package = Package(
    name: "SeedDemoStore",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../../CheerioKit")],
    targets: [
        .executableTarget(
            name: "SeedDemoStore",
            dependencies: [.product(name: "CheerioKit", package: "CheerioKit")]
        )
    ]
)
