import AVFoundation
import Foundation

/// A single tap buffer's loudness, computed synchronously so the arithmetic can
/// run directly inside the realtime callback that produces it — see
/// `MicrophoneCapture.levels`. Linear amplitude, not dBFS, so silence is exactly
/// `.silence` rather than negative infinity needing a special case at every
/// call site.
public struct AudioLevel: Sendable, Equatable {
    /// Root-mean-square amplitude across every channel and frame in the buffer,
    /// linear 0...1.
    public let rms: Float
    /// The single loudest sample in the buffer, linear 0...1.
    public let peak: Float

    public static let silence = AudioLevel(rms: 0, peak: 0)

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    /// One pass over samples already resident in `buffer` — no allocation, no
    /// locking, no I/O — so it costs a realtime audio callback nothing that
    /// copying the buffer out to measure later wouldn't also cost, and the
    /// buffer itself never has to leave the tap to produce a meter reading.
    /// Non-float formats report silence instead of trapping on a nil
    /// `floatChannelData`; nothing in this app's capture path produces one.
    public static func measuring(_ buffer: AVAudioPCMBuffer) -> AudioLevel {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0, let channelData = buffer.floatChannelData else {
            return .silence
        }

        var sumOfSquares: Float = 0
        var peak: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let magnitude = abs(samples[frame])
                sumOfSquares += magnitude * magnitude
                peak = max(peak, magnitude)
            }
        }
        let meanSquare = sumOfSquares / Float(frameCount * channelCount)
        return AudioLevel(rms: min(meanSquare.squareRoot(), 1), peak: min(peak, 1))
    }

    /// `rms` mapped onto 0...1 for a level bar. In dBFS, clamped to a floor,
    /// rather than linear amplitude: linear leaves ordinary close-mic'd speech
    /// (roughly -30 to -15 dBFS) pinned in the bottom quarter of the bar, which
    /// reads as "not hearing you" even when the sample is perfectly usable.
    public var meterFraction: Double {
        guard rms > 0 else { return 0 }
        let dBFS = 20 * log10(Double(rms))
        let floor = -50.0
        let ceiling = -6.0
        return min(max((dBFS - floor) / (ceiling - floor), 0), 1)
    }
}
