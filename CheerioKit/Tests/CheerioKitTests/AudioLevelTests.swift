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
}
