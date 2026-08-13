import AVFoundation
import Foundation
import Testing

@testable import CheerioKit

/// Driving transcription from a retained file, verified as far as it can be without
/// a speech model installed — which is further than it sounds, because the part
/// issue #14 depends on isn't the recognizer.
///
/// What re-transcription adds to the live path is exactly two things: audio arriving
/// from a file instead of a microphone, and a file outrunning the analyzer. Both are
/// checkable here. Whether `SpeechTranscriber` then produces the right *words* is
/// the same question the live path already answers, and asking it in a unit test
/// would mean downloading a locale asset and asserting on a model's output.
///
/// The recording under test is deliberately issue #174's shape — one physical
/// microphone presented as three channels at 24 kHz, signal on channel 0 only.
/// That is the meeting this feature exists to recover, and reading it back through
/// `AnalyzerAudioConverter` is what proves the file path inherits #176's fix rather
/// than re-introducing the silent channel map beside it.
@Suite struct AudioFileTranscriptionTests {
    /// The format `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` reports
    /// on macOS 26 for an en-US transcriber: mono Int16 at 16 kHz. A literal, so
    /// this suite needs no installed model — same reasoning as
    /// `AnalyzerAudioConverterTests`.
    private func analyzerFormat() throws -> AVAudioFormat {
        try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    }

    /// Writes a CAF the way `MeetingAudioRecorder` does — the device's own format,
    /// verbatim, since that file is the evidence a wrong transcript is checked
    /// against.
    private func writeRetainedRecording(
        channels: UInt32,
        sampleRate: Double,
        seconds: Double,
        activeChannels: Set<Int>,
        amplitude: Float = 0.5,
        silentUntil: Double = 0
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "file-transcription-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "me.caf")

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        // More than two channels can't be described without a layout, and
        // `discreteInOrder` is what a virtual or aggregate input device reports —
        // the layout whose default channel map is `[-1]`.
        let format: AVAudioFormat
        if channels > 2 {
            let layout = try #require(
                AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
            format = try #require(AVAudioFormat(streamDescription: &description, channelLayout: layout))
        } else {
            format = try #require(AVAudioFormat(streamDescription: &description))
        }

        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData)
        let stride = buffer.stride
        let firstActiveFrame = Int(silentUntil * sampleRate)
        for channel in 0..<Int(channels) {
            let pointer = format.isInterleaved ? samples[0] + channel : samples[channel]
            for frame in 0..<Int(frames) {
                let active = activeChannels.contains(channel) && frame >= firstActiveFrame
                pointer[frame * stride] = active ? amplitude * sin(Float(frame) * 0.05) : 0
            }
        }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        try file.write(from: buffer)
        return url
    }

    private func peak(ofInt16 buffer: AVAudioPCMBuffer) throws -> Float {
        let samples = try #require(buffer.int16ChannelData)
        var loudest: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
            loudest = max(loudest, abs(Float(samples[0][frame * buffer.stride]) / 32_768))
        }
        return loudest
    }

    /// The acceptance property, one layer below the recognizer: read issue #174's
    /// recording back off disk, hand every window to the same converter the live
    /// engine feeds, and the analyzer's format comes out carrying the voice.
    ///
    /// Before #176 this is the case that produced perfect digital silence for 58
    /// minutes with no error anywhere — a 3-channel discrete layout maps to `[-1]`,
    /// "this output channel has no source". A silent result here would be that bug,
    /// reachable again through the file path.
    @Test func aThreeChannelRecordingReadsBackAsAudioTheAnalyzerCanHear() async throws {
        let url = try writeRetainedRecording(
            channels: 3, sampleRate: 24_000, seconds: 2, activeChannels: [0])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let target = try analyzerFormat()
        let converter = AnalyzerAudioConverter(channel: .me, target: target)
        let file = try AVAudioFile(forReading: url)
        var convertedFrames: AVAudioFrameCount = 0
        var loudest: Float = 0
        // 4,096-frame windows so this runs the multi-window loop the real 58-minute
        // file runs, rather than the degenerate single-window case.
        try await ChunkedAudioReader.readAwaitingEachWindow(file, windowFrames: 4_096) { window in
            let converted = try #require(converter.convert(window))
            #expect(converted.format == target)
            convertedFrames += converted.frameLength
            let windowPeak = try peak(ofInt16: converted)
            loudest = max(loudest, windowPeak)
        }

        // Two seconds at 24 kHz becomes two seconds at 16 kHz, give or take the
        // resampler's own latency at each window boundary.
        #expect(abs(Int(convertedFrames) - 32_000) < 1_000)
        // A third of full scale: the mean downmix attenuates one active channel of
        // three by 9.5 dB, which is the documented cost of never clipping.
        #expect(loudest > 0.1)
    }

    /// The feeding half: a file is read in bounded windows and each one is *awaited*,
    /// so the whole recording is never resident at once. Pinned by holding the
    /// consumer back — a reader that ignored the await would have read the file to
    /// the end before the first window was released.
    @Test func windowsAreReadOneAtATimeAsTheConsumerTakesThem() async throws {
        let url = try writeRetainedRecording(
            channels: 1, sampleRate: 16_000, seconds: 4, activeChannels: [0])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let file = try AVAudioFile(forReading: url)
        let length = file.length
        var windows = 0
        var handedOver: AVAudioFramePosition = 0
        var framesReadAhead: AVAudioFramePosition = 0
        try await ChunkedAudioReader.readAwaitingEachWindow(file, windowFrames: 8_000) { window in
            windows += 1
            // Yielding is enough: a reader that didn't wait would have run the file
            // to its end while this consumer was suspended here.
            await Task.yield()
            handedOver += AVAudioFramePosition(window.frameLength)
            framesReadAhead = max(framesReadAhead, file.framePosition - handedOver)
        }

        #expect(windows > 1)
        #expect(handedOver == length)
        // Nothing was ever read that the consumer hadn't been handed — one window in
        // flight at a time, whatever the recording's length.
        #expect(framesReadAhead == 0)
    }

    /// `AudioFileSignal` is what the after-the-fact coverage verdict is built on, so
    /// it has to report the device's format rather than the shape `AVAudioFile`
    /// decodes into — 3 ch / 24 kHz is the fact that made issue #174 diagnosable.
    @Test func measuringAFileReportsTheFormatTheDeviceRecordedIn() throws {
        let url = try writeRetainedRecording(
            channels: 3, sampleRate: 24_000, seconds: 2, activeChannels: [0], amplitude: 0.5)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let signal = try AudioFileSignal.measuring(url)
        #expect(signal.format == CapturedAudioFormat(channelCount: 3, sampleRate: 24_000))
        #expect(abs(signal.duration - 2) < 0.01)
        #expect(abs(signal.peak - 0.5) < 0.01)
        #expect(CapturePeakWatch.Verdict(peak: signal.peak).isSignal)
    }

    /// The bound the repair prompt scans under, and what it costs: audio that only
    /// starts talking after the budget reads as silent. Documented on
    /// `TranscriptRepair.promptScanBudget` — the prompt is a courtesy, and the
    /// affordance never depended on it — but it has to be a bound that actually
    /// bounds, or the in-person meeting case it exists for still reads the hour.
    @Test func aBoundedScanOnlyLooksAtTheSecondsItWasGiven() throws {
        // Long enough to span more than one read window (~65 seconds of 16 kHz
        // audio), with the speech starting in the second one — the budget can't cut
        // finer than a window, which is what its doc says.
        let url = try writeRetainedRecording(
            channels: 1, sampleRate: 16_000, seconds: 140, activeChannels: [0], silentUntil: 100)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let whole = try AudioFileSignal.measuring(url)
        #expect(CapturePeakWatch.Verdict(peak: whole.peak).isSignal)

        let bounded = try AudioFileSignal.measuring(url, scanning: 1, stoppingAtFirstSignal: true)
        #expect(bounded.peak == 0)
        // The length is the whole recording's either way — only the scan is bounded.
        #expect(abs(bounded.duration - 140) < 0.01)
    }

    @Test func measuringASilentFileClearsNoSilenceFloor() throws {
        let url = try writeRetainedRecording(
            channels: 1, sampleRate: 16_000, seconds: 1, activeChannels: [], amplitude: 0)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let signal = try AudioFileSignal.measuring(url)
        #expect(signal.peak == 0)
        #expect(!CapturePeakWatch.Verdict(peak: signal.peak).isSignal)
    }
}
