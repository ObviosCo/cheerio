import AVFoundation
import Foundation
import Testing

@testable import CheerioKit

/// The format `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` reports on
/// macOS 26 for an en-US `SpeechTranscriber`: mono Int16 at 16 kHz. Pinned as a
/// literal rather than asked for at test time, so these tests exercise the
/// conversion arithmetic without an installed speech model.
private func analyzerFormat() throws -> AVAudioFormat {
    try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
}

/// Builds a capture format the way a device reports one: any channel count, any
/// rate. More than two channels *requires* a channel layout — `AVAudioFormat`
/// refuses to describe them without one — and `discreteInOrder` is what a virtual
/// or aggregate input device reports, which is precisely the case issue #174's
/// 3 ch / 24 kHz mic hit.
private func captureFormat(
    channels: UInt32,
    sampleRate: Double,
    interleaved: Bool = true,
    bitsPerChannel: UInt32 = 32,
    isFloat: Bool = true,
    discreteLayout: Bool = true
) throws -> AVAudioFormat {
    let bytes = bitsPerChannel / 8
    var description = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
            | kAudioFormatFlagIsPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
        mBytesPerPacket: interleaved ? bytes * channels : bytes,
        mFramesPerPacket: 1,
        mBytesPerFrame: interleaved ? bytes * channels : bytes,
        mChannelsPerFrame: channels,
        mBitsPerChannel: bitsPerChannel,
        mReserved: 0
    )
    guard channels > 2 || discreteLayout else {
        return try #require(AVAudioFormat(streamDescription: &description))
    }
    let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
    return try #require(AVAudioFormat(streamDescription: &description, channelLayout: layout))
}

/// A sine at half scale on `activeChannels`, digital silence on the rest — the shape
/// of a virtual device that presents one physical microphone as three channels.
private func makeBuffer(
    format: AVAudioFormat, frames: AVAudioFrameCount = 4_096, activeChannels: Set<Int>? = nil
) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData)
    let stride = buffer.stride
    for channel in 0..<Int(format.channelCount) {
        let pointer = format.isInterleaved ? samples[0] + channel : samples[channel]
        let active = activeChannels?.contains(channel) ?? true
        for frame in 0..<Int(frames) {
            pointer[frame * stride] = active ? 0.5 * sin(Float(frame) * 0.05) : 0
        }
    }
    return buffer
}

private func peak(of buffer: AVAudioPCMBuffer) throws -> Float {
    switch buffer.format.commonFormat {
    case .pcmFormatInt16:
        let samples = try #require(buffer.int16ChannelData)
        var loudest: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
            loudest = max(loudest, abs(Float(samples[0][frame * buffer.stride]) / 32_768))
        }
        return loudest
    case .pcmFormatFloat32:
        let samples = try #require(buffer.floatChannelData)
        var loudest: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let pointer = buffer.format.isInterleaved ? samples[0] + channel : samples[channel]
            for frame in 0..<Int(buffer.frameLength) {
                loudest = max(loudest, abs(pointer[frame * buffer.stride]))
            }
        }
        return loudest
    default:
        Issue.record("unhandled format in peak(of:)")
        return 0
    }
}

@Suite struct AnalyzerAudioConverterTests {
    /// Issue #174's exact case: a 3 ch / 24 kHz mic. Before the mono downmix, this
    /// produced a full-length buffer of pure zeros — the analyzer transcribed
    /// nothing from 58 minutes of audible speech and nothing anywhere failed.
    @Test func threeChannel24kHzProducesAudibleMono() throws {
        let target = try analyzerFormat()
        let source = try captureFormat(channels: 3, sampleRate: 24_000)
        let converter = AnalyzerAudioConverter(channel: .me, target: target)
        let converted = try #require(converter.convert(try makeBuffer(format: source, activeChannels: [0])))

        #expect(converted.format == target)
        #expect(converted.format.channelCount == 1)
        #expect(converted.format.sampleRate == 16_000)
        // 4096 frames at 24 kHz is 2730 at 16 kHz; the resampler withholds a little
        // of its own latency, so only the order of magnitude is contractual.
        #expect(converted.frameLength > 2_000)
        #expect(try peak(of: converted) > 0.1)
    }

    /// The working baseline from the same machine, which must not regress.
    @Test func monoFortyEightKilohertzStillTranscribes() throws {
        let target = try analyzerFormat()
        let source = try captureFormat(channels: 1, sampleRate: 48_000, interleaved: false, discreteLayout: false)
        let converter = AnalyzerAudioConverter(channel: .me, target: target)
        let converted = try #require(converter.convert(try makeBuffer(format: source)))

        #expect(converted.format == target)
        #expect(converted.frameLength > 1_000)
        // A single channel is passed through the downmix unscaled, so the level
        // survives the conversion intact.
        #expect(abs(try peak(of: converted) - 0.5) < 0.01)
    }

    @Test func stereoAtFortyFourOneKilohertzProducesAudibleMono() throws {
        let target = try analyzerFormat()
        let source = try captureFormat(channels: 2, sampleRate: 44_100, discreteLayout: false)
        let converter = AnalyzerAudioConverter(channel: .them, target: target)
        let converted = try #require(converter.convert(try makeBuffer(format: source)))

        #expect(converted.format == target)
        #expect(converted.frameLength > 1_000)
        // Both channels carry the same signal, so averaging preserves the level
        // rather than halving it.
        #expect(abs(try peak(of: converted) - 0.5) < 0.01)
    }

    /// A high channel count is where taking channel 0 (or trusting
    /// `AVAudioConverter`'s default map) is most likely to land on a silent channel.
    @Test func eightChannelInputSurvivesWhateverChannelCarriesTheVoice() throws {
        let target = try analyzerFormat()
        let source = try captureFormat(channels: 8, sampleRate: 48_000)
        for voiceChannel in 0..<8 {
            let converter = AnalyzerAudioConverter(channel: .me, target: target)
            let converted = try #require(
                converter.convert(try makeBuffer(format: source, activeChannels: [voiceChannel])))
            #expect(converted.format == target)
            #expect(try peak(of: converted) > 0.01, "channel \(voiceChannel) was lost")
        }
    }

    /// Non-float samples are lifted to float32 first, at the same channel count and
    /// rate, so the channel collapse is still ours and not the converter's.
    @Test func int16CaptureIsConverted() throws {
        let target = try analyzerFormat()
        let source = try captureFormat(channels: 3, sampleRate: 32_000, bitsPerChannel: 16, isFloat: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 2_048))
        buffer.frameLength = 2_048
        let samples = try #require(buffer.int16ChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<3 {
                samples[0][frame * buffer.stride + channel] = Int16(8_000 * sin(Double(frame) * 0.05))
            }
        }

        let converter = AnalyzerAudioConverter(channel: .me, target: target)
        let converted = try #require(converter.convert(buffer))
        #expect(converted.format == target)
        #expect(try peak(of: converted) > 0.1)
    }

    /// The same converter is reused for every buffer of a recording (the resampler
    /// keeps state across them), so a long run must not degrade.
    @Test func successiveBuffersAllConvert() throws {
        let target = try analyzerFormat()
        let source = try captureFormat(channels: 3, sampleRate: 24_000)
        let converter = AnalyzerAudioConverter(channel: .me, target: target)
        for _ in 0..<20 {
            let converted = try #require(converter.convert(try makeBuffer(format: source, activeChannels: [1])))
            #expect(try peak(of: converted) > 0.1)
        }
    }

    /// A device switch mid-recording changes the capture format under a converter
    /// that has already been built for the old one.
    @Test func aFormatChangeMidStreamIsHandled() throws {
        let target = try analyzerFormat()
        let converter = AnalyzerAudioConverter(channel: .me, target: target)
        let first = try #require(
            converter.convert(try makeBuffer(format: try captureFormat(channels: 3, sampleRate: 24_000))))
        #expect(try peak(of: first) > 0.1)
        let second = try #require(
            converter.convert(
                try makeBuffer(
                    format: try captureFormat(
                        channels: 1, sampleRate: 48_000, interleaved: false, discreteLayout: false))))
        #expect(try peak(of: second) > 0.1)
    }

    /// A buffer already in the analyzer's format shouldn't be copied or converted.
    @Test func matchingFormatPassesThrough() throws {
        let target = try analyzerFormat()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 512))
        buffer.frameLength = 512
        let converter = AnalyzerAudioConverter(channel: .them, target: target)
        #expect(converter.convert(buffer) === buffer)
    }

    /// The mechanism, pinned: handing `AVAudioConverter` the channel reduction
    /// directly reports complete success and emits nothing but zeros. This is what
    /// `AnalyzerAudioConverter` exists to route around, and the reason issue #174
    /// produced no error, no warning and no transcript. If this ever starts failing,
    /// the platform has changed and the manual downmix could be revisited — not
    /// before.
    @Test func aDirectChannelReductionSilentlyProducesSilence() throws {
        let target = try analyzerFormat()
        let source = try captureFormat(channels: 3, sampleRate: 24_000)
        let converter = try #require(AVAudioConverter(from: source, to: target))
        #expect(converter.channelMap == [-1])

        let input = try makeBuffer(format: source, activeChannels: [0])
        let output = try #require(
            AVAudioPCMBuffer(pcmFormat: target, frameCapacity: input.frameLength))
        var error: NSError?
        var handed = false
        converter.convert(to: output, error: &error) { _, status in
            if handed {
                status.pointee = .noDataNow
                return nil
            }
            handed = true
            status.pointee = .haveData
            return input
        }
        // No error, a full-length result, and every sample zero.
        #expect(error == nil)
        #expect(output.frameLength > 2_000)
        #expect(try peak(of: output) == 0)
    }

    @Test func emptyBuffersAreDropped() throws {
        let target = try analyzerFormat()
        let source = try captureFormat(channels: 3, sampleRate: 24_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 512))
        buffer.frameLength = 0
        let converter = AnalyzerAudioConverter(channel: .me, target: target)
        #expect(converter.convert(buffer) == nil)
    }
}

@Suite struct MonoDownmixTests {
    @Test func averagesEveryChannel() throws {
        let format = try captureFormat(channels: 3, sampleRate: 24_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try #require(buffer.floatChannelData)
        // Frame 0: 0.3 / 0.6 / 0.9 → 0.6. Frame 1: 1.0 / -1.0 / 0 → 0.
        let values: [[Float]] = [[0.3, 0.6, 0.9], [1, -1, 0], [0, 0, 0], [0.6, 0.6, 0.6]]
        for (frame, frameValues) in values.enumerated() {
            for (channel, value) in frameValues.enumerated() {
                samples[0][frame * buffer.stride + channel] = value
            }
        }

        let mono = try #require(AnalyzerAudioConverter.monoDownmix(of: buffer))
        #expect(mono.format.channelCount == 1)
        #expect(mono.format.sampleRate == 24_000)
        #expect(mono.frameLength == 4)
        let out = try #require(mono.floatChannelData)
        #expect(abs(out[0][0] - 0.6) < 0.0001)
        #expect(abs(out[0][1]) < 0.0001)
        #expect(abs(out[0][2]) < 0.0001)
        #expect(abs(out[0][3] - 0.6) < 0.0001)
    }

    /// Non-interleaved is what an `AVAudioEngine` input tap delivers; interleaved is
    /// what the system tap does. Both have to land on the same mono samples.
    @Test func handlesInterleavedAndNonInterleavedAlike() throws {
        let interleaved = try makeBuffer(
            format: try captureFormat(channels: 3, sampleRate: 24_000, interleaved: true), frames: 256,
            activeChannels: [2])
        let planar = try makeBuffer(
            format: try captureFormat(channels: 3, sampleRate: 24_000, interleaved: false), frames: 256,
            activeChannels: [2])

        let fromInterleaved = try #require(AnalyzerAudioConverter.monoDownmix(of: interleaved))
        let fromPlanar = try #require(AnalyzerAudioConverter.monoDownmix(of: planar))
        let left = try #require(fromInterleaved.floatChannelData)
        let right = try #require(fromPlanar.floatChannelData)
        for frame in 0..<256 {
            #expect(abs(left[0][frame] - right[0][frame]) < 0.0001)
        }
        // One of three channels active: a third of the input's half-scale peak.
        #expect(abs(try peak(of: fromInterleaved) - 0.5 / 3) < 0.001)
    }

    /// The mean can only attenuate, so no channel count can drive the result past
    /// full scale into the Int16 target's non-existent headroom.
    @Test func neverExceedsFullScale() throws {
        let format = try captureFormat(channels: 6, sampleRate: 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        let samples = try #require(buffer.floatChannelData)
        for frame in 0..<64 {
            for channel in 0..<6 {
                samples[0][frame * buffer.stride + channel] = 1
            }
        }
        let mono = try #require(AnalyzerAudioConverter.monoDownmix(of: buffer))
        #expect(try peak(of: mono) <= 1)
    }

    @Test func monoInputIsReturnedUntouched() throws {
        let buffer = try makeBuffer(
            format: try captureFormat(channels: 1, sampleRate: 48_000, interleaved: false, discreteLayout: false),
            frames: 64)
        #expect(AnalyzerAudioConverter.monoDownmix(of: buffer) === buffer)
    }
}
