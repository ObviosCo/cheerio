import AVFoundation
import Foundation

/// The two facts a capture format is diagnosed by, as plain values.
///
/// Deliberately not an `AVAudioFormat`: a capture source only learns its format once
/// the device is open, so the format has to be stored after `start()` and read later
/// from whoever is assembling a verdict. Copying the scalars out means the capture
/// sources — `Sendable` classes wrapping a realtime audio path — never have to hand a
/// non-Sendable object across that gap.
///
/// Worth recording at all because an input device can report anything: issue #174's
/// microphone was a virtual device presenting one physical mic as 3 channels at
/// 24 kHz, and that shape is the first thing a lost channel needs to be diagnosed
/// with.
public struct CapturedAudioFormat: Sendable, Equatable {
    public let channelCount: Int
    public let sampleRate: Double

    public init(channelCount: Int, sampleRate: Double) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }

    public init(_ format: AVAudioFormat) {
        self.init(channelCount: Int(format.channelCount), sampleRate: format.sampleRate)
    }

    /// Log-ready: "3 ch / 24000 Hz".
    public var description: String {
        "\(channelCount) ch / \(Int(sampleRate)) Hz"
    }
}
