import AVFoundation
import Foundation

/// What a retained recording measures, read back off disk: how loud it ever got,
/// what format the device delivered, and how long it runs.
///
/// The after-the-fact counterpart of `CapturePeakWatch`, which answers the same
/// loudness question live from the capture callback. A meeting already in the
/// library has no capture source left to ask — the peak and the format were held
/// in memory by objects released when the recording stopped — so the only
/// remaining witness is the CAF itself. That matters for re-transcription (issue
/// #14): "this channel captured real audio and produced no transcript" is the
/// verdict worth acting on, and after the fact the file is where the first half of
/// it comes from.
///
/// The format comes from `fileFormat`, not `processingFormat`: what's on disk is
/// what the device delivered (issue #174's 3 ch / 24 kHz virtual mic), while
/// `processingFormat` is the float32 shape `AVAudioFile` decodes into and would
/// describe every recording identically.
public struct AudioFileSignal: Sendable, Equatable {
    /// The loudest sample found, linear 0...1 — pair with
    /// `CapturePeakWatch.Verdict(peak:)` for the silence-floor decision, so the
    /// threshold lives in one place rather than being restated here.
    ///
    /// "Found", not "in the file": a bounded or early-stopping scan (see
    /// ``measuring(_:scanning:stoppingAtFirstSignal:)``) reports the loudest sample
    /// it actually looked at, which is a lower bound on the recording's true peak.
    /// That's all a signal-or-silence verdict needs, and the parameters that bound
    /// the scan are the caller's to pass.
    public let peak: Float
    /// The format the file was written in, i.e. what the capture device reported.
    public let format: CapturedAudioFormat
    /// The whole recording's length, whatever was scanned of it.
    public let duration: TimeInterval

    public init(peak: Float, format: CapturedAudioFormat, duration: TimeInterval) {
        self.peak = peak
        self.format = format
        self.duration = duration
    }

    /// Reads `url` in bounded windows and reports the loudest sample it sees.
    ///
    /// Reads through `ChunkedAudioReader` for its short-read and end-of-file
    /// discipline, and measures with `AudioLevel`, so this owns no sample loop of
    /// its own. It is still a full pass over real audio — 58 minutes at
    /// 3 ch / 24 kHz is around 250 million samples — so it belongs off the main
    /// actor whatever the bounds.
    ///
    /// - Parameters:
    ///   - budget: how many seconds from the start to look at, rounded up to a whole
    ///     `ChunkedAudioReader` window (about 22 seconds of 48 kHz audio) since
    ///     that's the granularity the read loop has. Nil scans the whole file, which
    ///     is what a true peak requires. A caller asking the cheaper question — "is
    ///     there speech in here at all" — should bound it: the silent `them.caf` of
    ///     an hour-long in-person meeting is 690 MB of digital zeroes, and reading
    ///     all of it to learn that is a cost paid over and over.
    ///   - stoppingAtFirstSignal: stop as soon as a window clears
    ///     `CapturePeakWatch.Verdict`'s silence floor. Turns the signal case —
    ///     including issue #174's meeting, which is loud from its first seconds —
    ///     into one window read instead of an hour of audio.
    public static func measuring(
        _ url: URL,
        scanning budget: TimeInterval? = nil,
        stoppingAtFirstSignal: Bool = false
    ) throws -> AudioFileSignal {
        let file = try AVAudioFile(forReading: url)
        let format = CapturedAudioFormat(file.fileFormat)
        let duration = file.durationSeconds
        let frameBudget = budget.map { AVAudioFramePosition($0 * file.processingFormat.sampleRate) }
        var peak: Float = 0
        do {
            // Thrown to leave the read loop early, since `ChunkedAudioReader` has no
            // "stop here" signal of its own and giving it one would put this
            // caller's budget arithmetic in every other caller's way.
            try ChunkedAudioReader.read(file) { window in
                peak = max(peak, AudioLevel.measuring(window).peak)
                if stoppingAtFirstSignal, CapturePeakWatch.Verdict(peak: peak).isSignal {
                    throw ScanComplete()
                }
                if let frameBudget, file.framePosition >= frameBudget {
                    throw ScanComplete()
                }
            }
        } catch is ScanComplete {
            // Answered, not failed.
        }
        return AudioFileSignal(peak: peak, format: format, duration: duration)
    }

    private struct ScanComplete: Error {}
}

extension AVAudioFile {
    /// How many seconds of audio the file holds. Zero, rather than a division by
    /// zero, for a header claiming no sample rate.
    var durationSeconds: TimeInterval {
        fileFormat.sampleRate > 0 ? Double(length) / fileFormat.sampleRate : 0
    }
}
