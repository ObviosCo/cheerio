import AVFoundation
import Foundation
import Testing

@testable import CheerioKit

private func makeFormat(channels: AVAudioChannelCount = 1) throws -> AVAudioFormat {
    try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: channels, interleaved: false))
}

private func makeConstantBuffer(amplitude: Float, frames: AVAudioFrameCount = 256) throws -> AVAudioPCMBuffer {
    let format = try makeFormat()
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channel = try #require(buffer.floatChannelData)[0]
    for frame in 0..<Int(frames) {
        channel[frame] = amplitude
    }
    return buffer
}

/// One value per channel, repeated for every frame, packed into the single
/// interleaved span `floatChannelData[0]` holds for an interleaved format —
/// there's no `floatChannelData[1]` to write a second channel into.
private func makeInterleavedBuffer(channelValues: [Float], frames: AVAudioFrameCount = 4) throws -> AVAudioPCMBuffer {
    let format = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: AVAudioChannelCount(channelValues.count), interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData)[0]
    for frame in 0..<Int(frames) {
        for (channel, value) in channelValues.enumerated() {
            samples[frame * channelValues.count + channel] = value
        }
    }
    return buffer
}

@Suite struct AudioLevelTests {
    @Test func silentBufferMeasuresAsSilence() throws {
        let level = AudioLevel.measuring(try makeConstantBuffer(amplitude: 0))
        #expect(level == .silence)
        #expect(level.meterFraction == 0)
    }

    @Test func fullScaleSignalMeasuresAtPeak() throws {
        let level = AudioLevel.measuring(try makeConstantBuffer(amplitude: 1))
        #expect(level.rms == 1)
        #expect(level.peak == 1)
        #expect(level.meterFraction == 1)
    }

    @Test func quietSignalReadsLowButNonzero() throws {
        let level = AudioLevel.measuring(try makeConstantBuffer(amplitude: 0.01))
        #expect(level.rms > 0)
        #expect(level.meterFraction > 0)
        #expect(level.meterFraction < 0.5)
    }

    @Test func meterFractionGrowsWithLoudness() throws {
        let quiet = AudioLevel.measuring(try makeConstantBuffer(amplitude: 0.02))
        let louder = AudioLevel.measuring(try makeConstantBuffer(amplitude: 0.2))
        #expect(louder.meterFraction > quiet.meterFraction)
    }

    @Test func zeroLengthBufferMeasuresAsSilence() throws {
        let format = try makeFormat()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 0
        #expect(AudioLevel.measuring(buffer) == .silence)
    }

    @Test func peakTracksTheLoudestChannel() throws {
        let format = try makeFormat(channels: 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<4 {
            channels[0][frame] = 0.1
            channels[1][frame] = 0.4
        }
        let level = AudioLevel.measuring(buffer)
        #expect(level.peak == 0.4)
    }

    @Test func interleavedBufferMeasuresOverTheWholeSpan() throws {
        let buffer = try makeInterleavedBuffer(channelValues: [0.1, 0.4])
        let level = AudioLevel.measuring(buffer)
        #expect(level.peak == 0.4)
        let expectedMeanSquare = (Float(0.1) * Float(0.1) + Float(0.4) * Float(0.4)) / 2
        #expect(abs(level.rms - expectedMeanSquare.squareRoot()) < 0.0001)
    }

    @Test func interleavedSilenceMeasuresAsSilence() throws {
        let buffer = try makeInterleavedBuffer(channelValues: [0, 0])
        #expect(AudioLevel.measuring(buffer) == .silence)
    }

    /// The same loudness, laid out two different ways, has to come back as the
    /// same reading — this is the actual claim behind "every channel and frame",
    /// not just that the interleaved path doesn't crash.
    @Test func interleavedAndNonInterleavedAgreeOnTheSameContent() throws {
        let interleaved = try makeInterleavedBuffer(channelValues: [0.2, 0.3])

        let nonInterleavedFormat = try makeFormat(channels: 2)
        let nonInterleaved = try #require(AVAudioPCMBuffer(pcmFormat: nonInterleavedFormat, frameCapacity: 4))
        nonInterleaved.frameLength = 4
        let channels = try #require(nonInterleaved.floatChannelData)
        for frame in 0..<4 {
            channels[0][frame] = 0.2
            channels[1][frame] = 0.3
        }

        let interleavedLevel = AudioLevel.measuring(interleaved)
        let nonInterleavedLevel = AudioLevel.measuring(nonInterleaved)
        #expect(interleavedLevel.peak == nonInterleavedLevel.peak)
        #expect(abs(interleavedLevel.rms - nonInterleavedLevel.rms) < 0.0001)
    }
}
