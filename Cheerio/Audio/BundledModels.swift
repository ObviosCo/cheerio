import Foundation

/// Locates the Core ML models shipped inside the app bundle.
///
/// Cheerio has no network entitlement, so models can never be downloaded — they
/// are fetched at build time by `Scripts/fetch-models.sh` and copied into
/// `Contents/Resources`.
enum BundledModels {
    /// Sortformer v2.1 (6-bit palettized), used for speaker diarization.
    /// Nil if someone built without running the fetch script.
    static var speakerDiarization: URL? {
        Bundle.main.url(forResource: "Sortformer_v2.1", withExtension: "mlmodelc")
    }
}
