import AVFoundation
import Foundation
import Testing

@testable import CheerioKit

/// Regression test for the streaming rewrite (issue #7): the pre-fix whole-file
/// path (`AudioConverter.resampleAudioFile` + `SortformerDiarizer.processComplete`)
/// and the current windowed path (`SpeakerAttributionService.attribute`, via
/// `ChunkedAudioReader` + `SortformerDiarizer.process(samples:)` +
/// `finalizeSession()`) must land on the same speaker turns for the same audio —
/// using less memory is not the win if it also changes who got labelled what.
///
/// FluidAudio's own `SortformerStreamingIntegrationTests` establish frame-count
/// parity between these two call patterns in the abstract, against FluidAudio's
/// own fixtures; this checks the same property end to end, through this repo's
/// actual `SpeakerAttributionService`, on real (if synthesized) speech.
///
/// Opt-in like this file's siblings — needs the bundled model:
///
///     CHEERIO_SORTFORMER_MODEL=/path/to/Sortformer_v2.1.mlmodelc \
///     swift test --filter DiarizationStreamingRegressionTests
///
/// The fixture is generated on the fly via `/usr/bin/say` rather than checked in
/// or supplied separately — this repo doesn't commit media, and unlike
/// `enrolledSpeakerIsNamed`/`diarizesRealRecording`, there's no reason to ask a
/// maintainer for a recording when macOS can make an equivalent one.
///
/// A pure tone or noise signal doesn't stand in for it, either: probed directly
/// against this same model, an amplitude-modulated multi-tone signal built to
/// *look* spectrally distinct per "speaker" produced zero detected speakers —
/// Sortformer is a speech model and reacts to nothing that isn't shaped like
/// speech. Two `say` voices reliably do produce two detected speakers (checked ad
/// hoc: 2 speakers, segments at roughly 0.0–8.4s and 10.0–18.3s for an ~8.5s clip
/// + 1.5s gap + ~8.7s clip). If `say` is missing, produces no audio, or the model
/// still finds nothing, the test skips rather than failing spuriously — it's
/// checking this PR's change, not asserting every machine has speech synthesis or
/// that these specific synthetic voices always trigger detection.
@Suite struct DiarizationStreamingRegressionTests {
    @Test func oldAndNewPathsProduceTheSameTurns() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["CHEERIO_SORTFORMER_MODEL"] else { return }
        let modelURL = URL(fileURLWithPath: modelPath)
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return }
        guard let fixture = try makeTwoSpeakerFixture() else { return }
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let oldTurns = try DiarizationMemoryHarness.wholeFileTurns(modelURL: modelURL, audioFile: fixture)
        let service = SpeakerAttributionService(modelURL: modelURL)
        let newTurns = try await service.attribute(audioFile: fixture)

        guard !oldTurns.isEmpty || !newTurns.isEmpty else {
            // Neither path found anything in this environment's synthesized
            // speech — a fixture/environment limitation, not evidence the two
            // paths agree. Nothing meaningful to assert either way.
            return
        }

        #expect(!newTurns.isEmpty, "old path found turns but the new path found none — that's exactly the regression this test is for")
        #expect(oldTurns.count == newTurns.count)

        for (old, new) in zip(oldTurns, newTurns) {
            #expect(old.label == new.label)
            // FluidAudio's own SortformerStreamingIntegrationTests tolerate up to
            // 1 frame (~80ms, config.frameDurationSeconds) of drift between the
            // streaming and offline call patterns — matched here rather than
            // requiring bit-for-bit timing equality.
            #expect(abs(old.startTime - new.startTime) < 0.09)
            #expect(abs(old.endTime - new.endTime) < 0.09)
        }
    }

    /// Builds an ~18-second two-speaker CAF: two distinct system voices, each a
    /// couple of sentences, separated by 1.5s of silence. Returns `nil` (the
    /// caller should skip, not fail) if `say` is unavailable or produces nothing
    /// usable.
    private func makeTwoSpeakerFixture() throws -> URL? {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "diarization-regression-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let clipA = directory.appending(path: "a.aiff")
        let clipB = directory.appending(path: "b.aiff")
        guard
            try speak(
                "Good morning everyone. Let's start by reviewing last week's progress on the project.",
                voice: "Samantha",
                to: clipA
            ),
            try speak(
                "Thanks for the update. I'm a bit worried about the timeline, so let's talk about that next.",
                voice: "Daniel",
                to: clipB
            )
        else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }

        guard let a = try? monoSamples(of: clipA), let b = try? monoSamples(of: clipB),
            !a.samples.isEmpty, !b.samples.isEmpty, a.sampleRate == b.sampleRate
        else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }

        var combined = a.samples
        combined.append(contentsOf: [Float](repeating: 0, count: Int(1.5 * a.sampleRate)))
        combined.append(contentsOf: b.samples)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: a.sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(combined.count))
        else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(combined.count)
        combined.withUnsafeBufferPointer { source in
            _ = memcpy(buffer.floatChannelData![0], source.baseAddress!, combined.count * MemoryLayout<Float>.stride)
        }

        let output = directory.appending(path: "combined.caf")
        let file = try AVAudioFile(forWriting: output, settings: format.settings)
        try file.write(from: buffer)
        return output
    }

    /// Runs `/usr/bin/say -v voice text -o destination`. Returns `false` (caller
    /// should skip, not fail) if the binary is missing or exits non-zero.
    private func speak(_ text: String, voice: String, to destination: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: "/usr/bin/say") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", destination.path, text]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Reads a whole small clip's mono samples at its native rate. Loops until
    /// `framePosition == length` rather than trusting one call — see
    /// `ChunkedAudioReader`'s doc for why a single `read(into:frameCount:)` call
    /// isn't reliable even for a file this short.
    private func monoSamples(of url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        var samples: [Float] = []
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: remaining) else { break }
            try file.read(into: buffer, frameCount: remaining)
            guard buffer.frameLength > 0 else { break }
            let data = buffer.floatChannelData![0]
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        return (samples, file.processingFormat.sampleRate)
    }
}
