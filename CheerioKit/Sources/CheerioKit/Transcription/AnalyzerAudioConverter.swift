import AVFoundation
import Foundation
import OSLog

/// Turns a captured buffer in *any* device format into the one format
/// `SpeechAnalyzer` asked for, by downmixing to mono ourselves and leaving
/// `AVAudioConverter` only the sample-rate and sample-depth work.
///
/// Handing `AVAudioConverter` a channel-count reduction directly is the trap this
/// type exists to avoid, and it is a silent one. Measured on macOS 26 against a
/// 3 ch / 24 kHz Float32 input and the analyzer's 1 ch / 16 kHz Int16 format
/// (issue #174 — a real 58-minute meeting whose mic channel peaked at −3.3 dBFS on
/// disk and produced zero transcript segments):
///
/// - `AVAudioConverter(from:to:)` succeeds, and `convert` reports no error and the
///   expected output frame count. Nothing anywhere fails.
/// - But the converter's default `channelMap` for a discrete or unknown input
///   channel layout — what a virtual or aggregate input device reports — is
///   `[-1]`: "this output channel has no source". Every output sample is zero, so
///   the analyzer is fed the whole meeting in perfect digital silence and
///   correctly transcribes nothing from it.
/// - Even a *known* three-channel layout (`MPEG_3_0_A`) only maps `[2]` — it picks
///   the centre channel rather than mixing, which for a virtual device carrying one
///   physical mic on channel 0 is equally silent. A stereo input maps `[0]`, i.e.
///   left only, so the 1 ch and 2 ch cases that worked did so by luck of channel
///   ordering, not because the conversion was right.
///
/// So the channel count is collapsed here, in code whose arithmetic is testable,
/// and `AVAudioConverter` is only ever asked to convert 1 channel to 1 channel —
/// the case where its default map is the identity.
///
/// This is the *transcriber* boundary deliberately, not the capture boundary: the
/// retained CAF stays a faithful recording of what the device delivered (it is the
/// evidence a wrong transcript is checked against, and re-transcription — issue
/// #14 — reads it back through this same conversion), while every consumer that
/// needs mono 16 kHz derives it here.
final class AnalyzerAudioConverter {
    /// The format `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`
    /// reported for this run's transcriber.
    let target: AVAudioFormat

    private let channel: SpeakerChannel
    private let log = Logger(subsystem: "co.obvios.cheerio.mac", category: "AnalyzerAudioConverter")

    /// Non-float32 input (some virtual devices deliver Int16, and CAF playback of a
    /// re-transcribed file could deliver anything) is lifted to float32 first,
    /// keeping the channel count and sample rate untouched so this converter's own
    /// channel map stays the identity. Rebuilt if the input format changes
    /// mid-recording, which a device switch can do.
    private var liftToFloat32: (source: AVAudioFormat, converter: AVAudioConverter)?
    /// Mono float32 at the input's rate → `target`. Retained across buffers on
    /// purpose: the resampler carries state between calls, and rebuilding it per
    /// buffer would put a discontinuity at every buffer boundary.
    private var toTarget: (source: AVAudioFormat, converter: AVAudioConverter)?
    /// Logged once per input format, so the log carries the shape of the
    /// conversion that actually ran — issue #174 left no diagnostic trail at all.
    private var announcedSource: AVAudioFormat?
    /// One failure per input format is enough to know the channel is dead; a
    /// per-buffer error would be thousands of lines a minute.
    private var reportedFailure: AVAudioFormat?

    init(channel: SpeakerChannel, target: AVAudioFormat) {
        self.channel = channel
        self.target = target
    }

    /// Converts one captured buffer into ``target``, or returns nil if it can't —
    /// having said so in the log, which is the difference between this and the
    /// early-returns that let issue #174 ship.
    ///
    /// Returns the input buffer itself when it is already in `target`'s format,
    /// so a device that happens to match costs nothing.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        guard buffer.format != target else { return buffer }
        announce(source: buffer.format)

        guard let mono = monoFloat32(from: buffer) else {
            report(failure: "couldn't reduce it to mono float32", source: buffer.format)
            return nil
        }
        guard mono.format != target else { return mono }
        guard let converter = converter(from: mono.format) else {
            report(failure: "no converter to the analyzer's format exists", source: buffer.format)
            return nil
        }
        guard let converted = Self.convert(mono, with: converter, to: target) else {
            report(failure: "the conversion to the analyzer's format produced nothing", source: buffer.format)
            return nil
        }
        return converted
    }

    // MARK: - Mono

    /// Averages every channel of `buffer` into a single float32 channel at the
    /// input's own sample rate.
    ///
    /// The mean, not the sum: the analyzer's format is Int16, which has no headroom
    /// to clip into, and correlated channels (the same voice on all of them, the
    /// usual case for a duplicating virtual device) would sum straight past full
    /// scale. The cost is attenuation when only one channel of several carries the
    /// voice — 3 channels with one active loses 9.5 dB — which an ASR front end's
    /// own normalization absorbs, while clipped phonemes are gone for good.
    ///
    /// Returns `buffer` unchanged when it is already mono float32, and nil when the
    /// samples aren't float32 at all rather than guessing at a representation it
    /// can't read — `liftedToFloat32` is what makes sure they are.
    ///
    /// Runs on the transcription engine's actor, one pass over one buffer, never on
    /// an audio callback.
    static func monoDownmix(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.commonFormat == .pcmFormatFloat32, let source = buffer.floatChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        guard channels > 0 else { return nil }
        guard channels > 1 else { return buffer }
        guard
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
            let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
            let destination = mono.floatChannelData
        else { return nil }
        mono.frameLength = buffer.frameLength

        // `stride` and the interleaved test together cover both layouts: a
        // non-interleaved buffer hands out one pointer per channel with stride 1,
        // an interleaved one a single pointer with stride == channelCount.
        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        let scale = 1 / Float(channels)
        let out = destination[0]
        for frame in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for channel in 0..<channels {
                let samples = interleaved ? source[0] + channel : source[channel]
                sum += samples[frame * stride]
            }
            out[frame] = sum * scale
        }
        return mono
    }

    private func monoFloat32(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.commonFormat != .pcmFormatFloat32 else { return Self.monoDownmix(of: buffer) }
        guard let lifted = liftedToFloat32(buffer) else { return nil }
        return Self.monoDownmix(of: lifted)
    }

    /// Same channel count, same sample rate, float32 samples — a conversion
    /// `AVAudioConverter` handles with an identity channel map for any layout,
    /// verified for Int16, Int32 and Float64 sources at 1, 3 and 8 channels.
    private func liftedToFloat32(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = buffer.format
        if liftToFloat32?.source != source {
            guard let twin = Self.float32Twin(of: source), let converter = AVAudioConverter(from: source, to: twin)
            else {
                liftToFloat32 = nil
                return nil
            }
            liftToFloat32 = (source, converter)
        }
        guard let converter = liftToFloat32?.converter else { return nil }
        return Self.convert(buffer, with: converter, to: converter.outputFormat)
    }

    /// A float32, non-interleaved format with `format`'s rate, channel count and
    /// channel layout. The layout has to be carried over: `AVAudioFormat` refuses
    /// to describe more than two channels without one, which is also why any input
    /// format wider than stereo is guaranteed to have one to copy.
    private static func float32Twin(of format: AVAudioFormat) -> AVAudioFormat? {
        var description = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: format.channelCount,
            mBitsPerChannel: 32,
            mReserved: 0)
        if let layout = format.channelLayout {
            return AVAudioFormat(streamDescription: &description, channelLayout: layout)
        }
        return AVAudioFormat(streamDescription: &description)
    }

    // MARK: - Target

    private func converter(from source: AVAudioFormat) -> AVAudioConverter? {
        if toTarget?.source != source {
            guard let converter = AVAudioConverter(from: source, to: target) else {
                toTarget = nil
                return nil
            }
            toTarget = (source, converter)
        }
        return toTarget?.converter
    }

    /// One `AVAudioConverter` pass over one buffer.
    ///
    /// The output capacity is the frame count the rate change implies, plus one for
    /// the rounding. A resampler withholds a few frames of its own latency, so a
    /// short result is normal and not an error.
    private static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        // `AVAudioConverterInputBlock` is `@Sendable`, but the converter calls it
        // synchronously before `convert` returns — the box just carries the
        // one-shot input past that annotation.
        let pending = PendingConverterInput(buffer: buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let next = pending.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    // MARK: - Diagnostics

    private func announce(source: AVAudioFormat) {
        guard announcedSource != source else { return }
        announcedSource = source
        // .notice so it survives to `log show`; .info is memory-only.
        log.notice(
            """
            \(self.channel.rawValue, privacy: .public) channel transcribing \
            \(Self.describe(source), privacy: .public) as \(Self.describe(self.target), privacy: .public)
            """
        )
    }

    private func report(failure: String, source: AVAudioFormat) {
        guard reportedFailure != source else { return }
        reportedFailure = source
        log.error(
            """
            \(self.channel.rawValue, privacy: .public) channel can't be transcribed: \
            \(Self.describe(source), privacy: .public) → \(Self.describe(self.target), privacy: .public), \
            \(failure, privacy: .public). This channel will produce no transcript.
            """
        )
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(format.channelCount) ch / \(Int(format.sampleRate)) Hz \(describe(format.commonFormat))"
    }

    private static func describe(_ commonFormat: AVAudioCommonFormat) -> String {
        switch commonFormat {
        case .pcmFormatFloat32: "float32"
        case .pcmFormatFloat64: "float64"
        case .pcmFormatInt16: "int16"
        case .pcmFormatInt32: "int32"
        case .otherFormat: "other"
        @unknown default: "unknown"
        }
    }
}

/// Holds the single buffer an `AVAudioConverter` pass should consume, and yields it
/// exactly once. Sound because the converter invokes its input block synchronously
/// on the thread that called `convert`.
private final class PendingConverterInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
