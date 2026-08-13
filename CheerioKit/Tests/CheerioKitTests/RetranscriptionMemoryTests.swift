import AVFoundation
import Foundation
import Speech
import Synchronization
import Testing

@testable import CheerioKit

/// Peak-RSS and queue-depth measurement for re-transcription (issue #14), in the
/// shape `DiarizationMemoryTests` established for issue #7/#117: run the real
/// production path over a real full-length recording and print a machine-readable
/// number, with the pre-fix strategy reproduced beside it as the baseline.
///
/// Opt-in, because it needs a long recording and a full pass takes tens of seconds.
/// Either point it at a real one, or have it generate a synthetic one of a given
/// length (`Scripts/diarization-memory-measure.sh`'s approach, so the measurement is
/// reproducible without anybody's meeting audio):
///
///     CHEERIO_RETRANSCRIBE_AUDIO=/path/to/me.caf \
///     swift test --package-path CheerioKit --filter RetranscriptionMemoryTests
///
///     CHEERIO_RETRANSCRIBE_MINUTES=58 \
///     swift test -c release --package-path CheerioKit --filter RetranscriptionMemoryTests
///
/// Run each test as its own `swift test` invocation when comparing numbers:
/// `getrusage`'s `ru_maxrss` is a high-water mark that never drops within a process,
/// so whichever ran first would pollute the other's figure. And prefer `-c release`
/// for the queue-depth question specifically: in a debug build the conversion loop is
/// slow enough to be the bottleneck itself, which hides how far a reader can outrun
/// the analyzer.
@Suite struct RetranscriptionMemoryTests {
    /// The recording to measure: a real one if given, otherwise a synthetic mono
    /// 16 kHz one of `CHEERIO_RETRANSCRIBE_MINUTES` minutes — deliberately the format
    /// that needs *no* downmix and no resample, since that's the case where reading
    /// costs nothing and a pushing reader can leave the analyzer furthest behind.
    private func resolvedSource() throws -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["CHEERIO_RETRANSCRIBE_AUDIO"] { return URL(filePath: path) }
        guard let minutes = environment["CHEERIO_RETRANSCRIBE_MINUTES"].flatMap(Double.init) else { return nil }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "retranscribe-memory-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "me.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        // Written a minute at a time so generating an hour doesn't itself need an
        // hour of audio in memory — the very thing being measured.
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 60))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            samples[0][frame] = 0.25 * sin(Float(frame) * 0.013)
        }
        for _ in 0..<Int(minutes.rounded()) {
            try file.write(from: buffer)
        }
        return url
    }

    private func reportPeakRSS(_ label: String) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("PEAK_RSS[\(label)]=\(usage.ru_maxrss)")
    }

    /// The production path: `AudioFileTranscription`, i.e. the analyzer pulling one
    /// window at a time out of `TranscriptionEngine.transcribe(file:)`.
    @Test func pullPathPeakRSS() async throws {
        guard let source = try resolvedSource() else { return }
        let lines = try await AudioFileTranscription.transcribe(audioFile: source, channel: .me)
        print("LINES[pull]=\(lines.count)")
        reportPeakRSS("pull")
    }

    /// The strategy this PR's first version used, reproduced here as the baseline:
    /// the same reader, the same converter, the same analyzer — but the reader
    /// *pushes* converted windows into an `AsyncStream` as fast as it can make them,
    /// and that stream's default buffering is unbounded. Nothing about it is
    /// throttled by what the analyzer has actually consumed, which is the defect.
    ///
    /// `MAX_QUEUED` is what makes it concrete: buffers yielded but not yet taken by
    /// the analyzer, at its worst moment. Each one is a converted mono 16 kHz Int16
    /// window (~2 MB per 1 M source frames of 24 kHz audio), so the count times that
    /// is memory nothing was ever going to reclaim before the pass ended.
    @Test func pushBaselinePeakRSS() async throws {
        guard let source = try resolvedSource() else { return }
        let transcriber = SpeechTranscriber(
            locale: .current,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let target = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]))
        let depth = QueueDepth()

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: DepthCountingInput(base: stream, depth: depth))

        let converter = AnalyzerAudioConverter(channel: .me, target: target)
        let file = try AVAudioFile(forReading: source)
        while let window = try ChunkedAudioReader.nextWindow(from: file) {
            guard let converted = converter.convert(window) else { continue }
            depth.yielded()
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        print("MAX_QUEUED[push]=\(depth.peak)")
        reportPeakRSS("push")
    }
}

/// How many converted buffers are sitting between the reader and the analyzer, and
/// the worst it ever got.
private final class QueueDepth: Sendable {
    private let state = Mutex<(current: Int, peak: Int)>((0, 0))

    func yielded() {
        state.withLock {
            $0.current += 1
            $0.peak = max($0.peak, $0.current)
        }
    }

    func taken() {
        state.withLock { $0.current -= 1 }
    }

    var peak: Int { state.withLock { $0.peak } }
}

/// The baseline's input sequence: the unbounded stream, with each element counted as
/// the analyzer takes it — the only place "taken" is observable from outside Speech.
private struct DepthCountingInput: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    typealias Failure = Never

    let base: AsyncStream<AnalyzerInput>
    let depth: QueueDepth

    struct Iterator: AsyncIteratorProtocol {
        var base: AsyncStream<AnalyzerInput>.AsyncIterator
        let depth: QueueDepth

        mutating func next() async -> AnalyzerInput? {
            let element = await base.next()
            if element != nil { depth.taken() }
            return element
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator(), depth: depth)
    }
}
