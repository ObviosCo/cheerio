import AVFoundation
import Foundation
import Testing

@testable import CheerioKit

@Suite struct ChunkedAudioReaderTests {
    /// Writes `frameCount` frames of a non-silent, non-repeating signal to a fresh
    /// mono CAF, so a dropped, duplicated, or reordered sample at a chunk boundary
    /// would actually show up as a mismatch rather than blending into silence.
    private func makeSyntheticCAF(frameCount: Int, sampleRate: Double = 48_000) throws -> URL {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "chunked-read-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let source = directory.appending(path: "source.caf")
        let input = try AVAudioFile(forWriting: source, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let data = buffer.floatChannelData![0]
        for i in 0..<frameCount {
            data[i] = sin(Float(i) * 0.013) * 0.5
        }
        try input.write(from: buffer)
        return source
    }

    /// The closest a caller can correctly get to "read the whole file in one call".
    ///
    /// There isn't a version of this that's actually one call: `read(into:frameCount:)`
    /// is documented to return fewer frames than requested even far from EOF — a
    /// 250,000-frame file handed a single 250,000-frame request here reliably came
    /// back with only 249,856 (a clean 61 × 4,096, apparently AVAudioFile's own
    /// internal I/O chunking, unrelated to any window size chosen by the caller).
    /// So "whole-file read" is itself necessarily a loop: ask for everything
    /// remaining, and if that came back short, ask again from the new
    /// `framePosition` — which is structurally the same loop `ChunkedAudioReader`
    /// runs with a smaller window. This is what makes the comparison below
    /// meaningful rather than tautological: it pins that shrinking the window
    /// doesn't change the result, using the largest window a caller could
    /// reasonably ask for as the baseline.
    private func wholeFileRead(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: remaining)!
            try file.read(into: buffer, frameCount: remaining)
            guard buffer.frameLength > 0 else { break }
            let data = buffer.floatChannelData![0]
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        return samples
    }

    /// The property issue #7 asks for directly: reading in bounded windows must
    /// yield exactly the same samples as reading the whole file in one buffer —
    /// windowing is a memory strategy, not a resampling or lossy step.
    @Test func chunkedReadMatchesWholeFileReadWithAPartialLastWindow() throws {
        // 250,000 frames over 4,096-frame windows leaves a partial last window,
        // exercising both the steady-state loop and the boundary.
        let source = try makeSyntheticCAF(frameCount: 250_000)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let reference = try wholeFileRead(source)

        let file = try AVAudioFile(forReading: source)
        var chunked: [Float] = []
        try ChunkedAudioReader.read(file, windowFrames: 4_096) { window in
            let data = window.floatChannelData![0]
            chunked.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(window.frameLength)))
        }

        #expect(chunked.count == reference.count)
        #expect(chunked == reference)
    }

    /// The length divides evenly into windows, so the loop's last read lands
    /// exactly on `framePosition == length`. `AVAudioFile.read(into:frameCount:)`
    /// throws if you try to read again from there — this pins that the reader
    /// stops instead of attempting one more (failing) read.
    @Test func chunkedReadStopsExactlyAtEndOfFileWithoutThrowing() throws {
        let source = try makeSyntheticCAF(frameCount: 8_192)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let reference = try wholeFileRead(source)

        let file = try AVAudioFile(forReading: source)
        var chunked: [Float] = []
        var windowCount = 0
        try ChunkedAudioReader.read(file, windowFrames: 4_096) { window in
            windowCount += 1
            let data = window.floatChannelData![0]
            chunked.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(window.frameLength)))
        }

        #expect(windowCount == 2)
        #expect(chunked == reference)
    }

    /// The awaiting variant (issue #14 feeds a `TranscriptionEngine` from a file
    /// with it) must be the same read, not a second one: same samples, same window
    /// boundaries, including the partial last window.
    @Test func awaitingReadMatchesTheSynchronousOne() async throws {
        let source = try makeSyntheticCAF(frameCount: 250_000)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        var synchronous: [Float] = []
        var synchronousWindows: [AVAudioFrameCount] = []
        try ChunkedAudioReader.read(try AVAudioFile(forReading: source), windowFrames: 4_096) { window in
            synchronousWindows.append(window.frameLength)
            let data = window.floatChannelData![0]
            synchronous.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(window.frameLength)))
        }

        var awaited: [Float] = []
        var awaitedWindows: [AVAudioFrameCount] = []
        try await ChunkedAudioReader.readAwaitingEachWindow(try AVAudioFile(forReading: source), windowFrames: 4_096) { window in
            awaitedWindows.append(window.frameLength)
            let data = window.floatChannelData![0]
            awaited.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(window.frameLength)))
        }

        #expect(awaitedWindows == synchronousWindows)
        #expect(awaited == synchronous)
    }

    /// A window bigger than the whole file is the degenerate one-chunk case —
    /// still must not throw or drop samples.
    @Test func windowLargerThanFileReadsEverythingInOneGo() throws {
        let source = try makeSyntheticCAF(frameCount: 1_000)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let reference = try wholeFileRead(source)

        let file = try AVAudioFile(forReading: source)
        var chunked: [Float] = []
        var windowCount = 0
        try ChunkedAudioReader.read(file, windowFrames: 1 << 20) { window in
            windowCount += 1
            let data = window.floatChannelData![0]
            chunked.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(window.frameLength)))
        }

        #expect(windowCount == 1)
        #expect(chunked == reference)
    }
}
