import Foundation
import Synchronization

/// Tracks the loudest reading a capture channel produced across one recording, so the
/// channel's `stop()` can log a signal-vs-silence verdict with a number attached. The
/// microphone counterpart of the pattern `SystemAudioTap`'s `SilenceWatch` established
/// for the system channel: several of the ways a mic goes quiet don't fail loud — the
/// engine runs, the tap fires, and every sample is zero or near it — so the only place
/// that failure surfaces after the fact is a log line written when the channel stops.
///
/// Deliberately *not* shared with `SystemAudioTap`'s watch: the tap has no per-buffer
/// level measurement to piggyback on, so its watch scans raw samples under a strict
/// frame budget and answers only "did any nonzero sample appear in the opening
/// seconds". The mic tap already computes an `AudioLevel` for every buffer (the level
/// meter), so tracking the true whole-recording peak costs one lock-free max per
/// buffer. Folding the two together would either unbound the tap callback's scan or
/// report an opening-window max as if it were the recording's peak.
public final class CapturePeakWatch: Sendable {
    /// The running max lives as a `Float` bit pattern: non-negative IEEE-754 values
    /// order the same way their bit patterns do, so a compare-exchange on the raw
    /// bits *is* a max on the values — no lock, which matters because `record` runs
    /// on the realtime audio thread and a lock there risks priority inversion
    /// against whoever reads `peak`.
    private let peakBits = Atomic<UInt32>(Float.zero.bitPattern)

    public init() {}

    /// Realtime-safe: lock-free, allocation-free, bounded. Non-finite or negative
    /// readings are dropped rather than clamped — NaN's bit pattern sorts above
    /// every real value and would wedge the max at garbage.
    public func record(peak: Float) {
        guard peak > 0, peak.isFinite else { return }
        let bits = peak.bitPattern
        var current = peakBits.load(ordering: .relaxed)
        while bits > current {
            let (exchanged, original) = peakBits.compareExchange(
                expected: current, desired: bits, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }

    /// The loudest reading recorded so far, linear 0...1.
    public var peak: Float { Float(bitPattern: peakBits.load(ordering: .acquiring)) }

    public var verdict: Verdict { Verdict(peak: peak) }

    public enum Verdict: Equatable, Sendable {
        /// The whole recording peaked below `silenceFloorDBFS` — nothing resembling
        /// speech was captured, whatever the samples technically contained.
        case silence(peak: Float)
        case signal(peak: Float)

        /// Where "technically nonzero" stops counting as signal. `SilenceWatch` can
        /// treat any nonzero sample as signal because a denied process tap delivers
        /// pure digital zeroes; a microphone is the opposite — a healthy open mic
        /// almost never produces exact zeroes (analog noise floor), while a broken
        /// one (an input device pointed at nothing, a driver delivering only its
        /// own residue) can produce nonzero samples that still contain no speech. So
        /// the mic's question is a level question, not a zero question. Ordinary
        /// close-mic'd speech peaks around −30…−3 dBFS and even far-field speech
        /// clears −50; a recording whose *peak across the entire take* never
        /// reached −60 dBFS captured no usable audio.
        public static let silenceFloorDBFS: Double = -60

        public init(peak: Float) {
            if let dBFS = Self.dBFS(fromLinear: peak), dBFS > Self.silenceFloorDBFS {
                self = .signal(peak: peak)
            } else {
                self = .silence(peak: peak)
            }
        }

        /// `nil` for exact zero rather than `-infinity`, so callers format the
        /// all-zeroes case in words instead of printing "-inf".
        public static func dBFS(fromLinear amplitude: Float) -> Double? {
            guard amplitude > 0 else { return nil }
            return 20 * log10(Double(amplitude))
        }

        public var peak: Float {
            switch self {
            case .silence(let peak), .signal(let peak):
                return peak
            }
        }

        /// Log-ready rendering of the peak: "-6.0 dBFS", or naming pure digital
        /// zeroes outright — an all-zero channel points at a permission or capture
        /// failure, where a nonzero-but-negligible one points at the input device,
        /// and the reader should be able to tell which.
        public var peakDescription: String {
            guard let dBFS = Self.dBFS(fromLinear: peak) else {
                return "every sample zero"
            }
            return String(format: "%.1f dBFS", dBFS)
        }
    }
}
