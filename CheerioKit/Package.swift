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
    dependencies: [
        // Speaker diarization (Sortformer) on Core ML / ANE. Apache-2.0.
        // Models are NOT downloaded at runtime — Cheerio has no network entitlement.
        // The app bundles the palettized model and passes its URL in; see
        // SpeakerAttributionService.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .target(
            name: "CheerioKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .testTarget(name: "CheerioKitTests", dependencies: ["CheerioKit"]),
    ]
)
