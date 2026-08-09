import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Test-only support for `Scripts/diarization-memory-measure.sh` and
/// `DiarizationStreamingRegressionTests`: reproduces the pre-fix whole-file
/// diarization path exactly, so both can compare it against
/// `SpeakerAttributionService.attribute` (the real, current production path)
/// instead of a hand-rolled stand-in that doesn't exercise Sortformer at all.
///
/// Not public API — `internal` so `@testable import CheerioKit` can reach it from
/// tests, and nothing outside tests/scripts has a reason to.
enum DiarizationMemoryHarness {
    /// `SpeakerAttributionService.attribute` before the streaming fix: the whole
    /// channel goes through `AudioConverter.resampleAudioFile` as one `[Float]`,
    /// then `SortformerDiarizer.processComplete`. Exists purely as this PR's
    /// "before" baseline — issue #7 is precisely that this path's peak scales
    /// with recording length. Discards the result; callers that need memory
    /// numbers read their own process's `getrusage` after calling this, callers
    /// that need the diarization result itself use `wholeFileTurns` instead.
    static func diarizeWholeFile(modelURL: URL, audioFile: URL) throws {
        _ = try wholeFileTurns(modelURL: modelURL, audioFile: audioFile)
    }

    /// Same pre-fix path as `diarizeWholeFile`, but returns the `[SpeakerTurn]`s
    /// so a caller can compare them against `SpeakerAttributionService.attribute`'s
    /// output for the regression test this PR's review asked for — issue #7's fix
    /// must not just use less memory, it must keep producing the same labels.
    static func wholeFileTurns(modelURL: URL, audioFile: URL) throws -> [SpeakerTurn] {
        let config = SortformerConfig.default
        let models = try loadModels(modelURL: modelURL, config: config)
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)

        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(audioFile)
        _ = try diarizer.processComplete(samples)
        return SpeakerAttributionService.turns(from: diarizer.timeline)
    }

    private static func loadModels(modelURL: URL, config: SortformerConfig) throws -> SortformerModels {
        guard modelURL.pathExtension == "mlmodelc" else {
            fatalError("loadModels only handles the compiled .mlmodelc form the app bundles")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = SortformerModels.recommendedComputeUnits(for: config)
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        return try SortformerModels(config: config, main: model)
    }
}
