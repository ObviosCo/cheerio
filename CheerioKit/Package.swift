// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CheerioKit",
    platforms: [
        .macOS("27.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "CheerioKit", targets: ["CheerioKit"])
    ],
    dependencies: [
        // Speaker diarization (Sortformer) on Core ML / ANE. Apache-2.0.
        // Models are NOT downloaded at runtime: nothing in the capture or processing
        // path may need the network. The app bundles them instead.
        // The app bundles the palettized model and passes its URL in; see
        // SpeakerAttributionService.
        //
        // Traits: Diarizer only. FluidAudio's defaults also enable TTS (Kokoro,
        // PocketTTS, LuxTTS and their bundled G2P resources) and
        // NemoTextProcessing (a prebuilt Rust xcframework downloaded at resolve
        // time). Cheerio uses neither, and leaving them on would ship both in the
        // app, with their licenses to carry in THIRD-PARTY-NOTICES.md. The
        // opt-out is what pins this manifest to tools 6.2: FluidAudio only exposes
        // the traits from its Package@swift-6.2.swift, and SwiftPM 6.1 still links
        // a trait-conditioned binary target.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.18.4",
            traits: ["Diarizer"]
        )
    ],
    targets: [
        .target(
            name: "CheerioKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .testTarget(
            name: "CheerioKitTests",
            dependencies: ["CheerioKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
