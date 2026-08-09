import Foundation
import Testing

@testable import CheerioKit

/// Peak-RSS measurement for `Scripts/diarization-memory-measure.sh`, driven through
/// the real bundled model and the real production code — not a stand-in.
///
/// Opt-in like `SpeakerAttributionTests`'s model-gated tests, and for the same
/// reason: the ~93 MB Sortformer model isn't in this repo.
///
///     CHEERIO_SORTFORMER_MODEL=/path/to/Sortformer_v2.1.mlmodelc \
///     CHEERIO_DIARIZATION_MEMORY_AUDIO=/path/to/synthetic.caf \
///     swift test --filter DiarizationMemoryTests
///
/// Each test is meant to run as its own `swift test` process invocation (which is
/// what the script does) — `getrusage`'s `ru_maxrss` is a high-water mark that
/// never drops within a process, so running both in one process would have
/// whichever ran first pollute the other's number.
@Suite struct DiarizationMemoryTests {
    private func environmentPaths() -> (model: URL, audio: URL)? {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["CHEERIO_SORTFORMER_MODEL"],
            let audioPath = environment["CHEERIO_DIARIZATION_MEMORY_AUDIO"]
        else { return nil }
        return (URL(fileURLWithPath: modelPath), URL(fileURLWithPath: audioPath))
    }

    private func reportPeakRSS(_ label: String) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        // Machine-parseable line the shell script greps for.
        print("PEAK_RSS[\(label)]=\(usage.ru_maxrss)")
    }

    /// The pre-fix path: whole channel as one `[Float]`, then `processComplete`.
    @Test func oldWholeFilePathPeakRSS() throws {
        guard let paths = environmentPaths() else { return }
        try DiarizationMemoryHarness.diarizeWholeFile(modelURL: paths.model, audioFile: paths.audio)
        reportPeakRSS("old")
    }

    /// The current production path: `SpeakerAttributionService.attribute`,
    /// windowed reads feeding `SortformerDiarizer.process(samples:)`.
    @Test func newWindowedPathPeakRSS() async throws {
        guard let paths = environmentPaths() else { return }
        let service = SpeakerAttributionService(modelURL: paths.model)
        _ = try await service.attribute(audioFile: paths.audio)
        reportPeakRSS("new")
    }
}
