// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CheerioKit",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "CheerioKit", targets: ["CheerioKit"])
    ],
    targets: [
        .target(name: "CheerioKit"),
        .testTarget(name: "CheerioKitTests", dependencies: ["CheerioKit"]),
    ]
)
