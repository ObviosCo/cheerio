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

    /// The same parity, on a real recording long enough for drift to show.
    ///
    /// The `say` fixture above is ~18 seconds, which is too short to catch the bug
    /// this exists for: FluidAudio before 0.15.6 (#807) emitted phantom frames from
    /// its streaming mel, and the error grew with length. On 20 minutes of a real
    /// in-person meeting, FluidAudio 0.15.5's streaming path agreed with its own
    /// whole-file path on only ~75% of speech frames, while 0.18.4 agrees on ~98%.
    /// Opt-in, and the whole-file side reads the clip into memory, so point it at
    /// minutes rather than hours:
    ///
    ///     CHEERIO_SORTFORMER_MODEL=/path/to/Sortformer_v2.1.mlmodelc \
    ///     CHEERIO_TEST_AUDIO=/path/to/recording.caf \
    ///     swift test --filter DiarizationStreamingRegressionTests
    @Test func streamingMatchesWholeFileOnARealRecording() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["CHEERIO_SORTFORMER_MODEL"],
            let audioPath = environment["CHEERIO_TEST_AUDIO"]
        else { return }
        let modelURL = URL(fileURLWithPath: modelPath)
        let audioURL = URL(fileURLWithPath: audioPath)

        let wholeFile = try DiarizationMemoryHarness.wholeFileTurns(modelURL: modelURL, audioFile: audioURL)
        let streamed = try await SpeakerAttributionService(modelURL: modelURL).attribute(audioFile: audioURL)
        guard !wholeFile.isEmpty || !streamed.isEmpty else { return }

        let agreement = try #require(Self.labelAgreement(wholeFile, streamed))
        #expect(agreement >= 0.95, "streaming agreed with whole-file on \(agreement) of shared speech frames")
    }

    @Test func labelAgreementIgnoresHowEachRunNumbersItsSpeakers() throws {
        let a = [
            SpeakerTurn(label: "Speaker 0", startTime: 0, endTime: 10),
            SpeakerTurn(label: "Speaker 1", startTime: 10, endTime: 20),
        ]
        let swapped = [
            SpeakerTurn(label: "Speaker 1", startTime: 0, endTime: 10),
            SpeakerTurn(label: "Speaker 0", startTime: 10, endTime: 20),
        ]
        let merged = [SpeakerTurn(label: "Speaker 0", startTime: 0, endTime: 20)]

        #expect(try #require(Self.labelAgreement(a, swapped)) == 1)
        // One run hears two people where the other hears one: half the frames agree.
        #expect(abs(try #require(Self.labelAgreement(a, merged)) - 0.5) < 0.01)
        #expect(abs(try #require(Self.labelAgreement(merged, a)) - 0.5) < 0.01)
        #expect(Self.labelAgreement(a, []) == nil)
    }

    /// The fraction of 0.1s frames heard as speech by both runs that carry the same
    /// speakers, under the best one-to-one mapping between the runs' labels. Each
    /// run numbers its speakers independently, so "Speaker 1" in one can be
    /// "Speaker 2" in the other. `nil` when no frame has speech in both.
    static func labelAgreement(_ a: [SpeakerTurn], _ b: [SpeakerTurn], step: TimeInterval = 0.1) -> Double? {
        let end = max(a.map(\.endTime).max() ?? 0, b.map(\.endTime).max() ?? 0)
        let frameCount = Int((end / step).rounded(.up))
        func frames(_ turns: [SpeakerTurn]) -> [Set<String>] {
            var result = [Set<String>](repeating: [], count: frameCount)
            for turn in turns {
                let first = Int(turn.startTime / step)
                let last = min(frameCount, Int(turn.endTime / step))
                guard first < last else { continue }
                for index in first..<last { result[index].insert(turn.label) }
            }
            return result
        }
        let framesA = frames(a)
        let framesB = frames(b)
        let shared = zip(framesA, framesB).filter { !$0.0.isEmpty && !$0.1.isEmpty }
        guard !shared.isEmpty else { return nil }

        let labelsA = Set(a.map(\.label)).sorted()
        // Pad with labels no turn carries, so a run that found more speakers still
        // gets a one-to-one mapping instead of none.
        var labelsB = Set(b.map(\.label)).sorted()
        while labelsB.count < labelsA.count { labelsB.append("unmatched-\(labelsB.count)") }

        var best = 0
        func search(_ mapping: [String: String], _ remaining: [String]) {
            guard mapping.count < labelsA.count else {
                let matches = shared.filter { Set($0.0.compactMap { mapping[$0] }) == $0.1 }.count
                best = max(best, matches)
                return
            }
            for (index, label) in remaining.enumerated() {
                var next = remaining
                next.remove(at: index)
                search(mapping.merging([labelsA[mapping.count]: label]) { $1 }, next)
            }
        }
        search([:], labelsB)
        return Double(best) / Double(shared.count)
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
