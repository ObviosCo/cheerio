import Foundation

/// One channel's answer to the only question a finished recording can be checked
/// against for free: did the audio it captured become text?
///
/// Signal in and nothing out is usually a bug, and always worth a look. Issue #174
/// is what that failure looks
/// like when nobody asks: a 58-minute meeting whose mic channel sat at −3.3 dBFS on
/// disk, produced zero transcript segments, and logged not one line about it — the
/// conversion feeding the analyzer had been handing it silence all along. The
/// existing silence verdicts (`CapturePeakWatch` for the mic, `SilenceWatch` for the
/// system tap) answer "did this channel hear anything", which was *yes* here, so
/// they had nothing to say.
///
/// Deliberately just arithmetic over facts the caller collects, so the decision is
/// testable without a recording: the capture sources own the signal facts, the store
/// owns the segment count, and this owns the verdict and the words for it.
public struct TranscriptionCoverage: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// Audio and text agree — either both are there, or the channel had no
        /// signal to transcribe.
        case consistent
        /// The channel captured nothing above its silence floor. Already diagnosed
        /// where it happened (a denied TCC grant, an input pointed at nothing, a
        /// sandboxed tap), so this is not this check's finding to report.
        case silentChannel
        /// The failure this check exists for: real audio, no text.
        ///
        /// A room loud enough to clear −60 dBFS in which nobody said anything the
        /// transcriber recognized can reach this too — an hour of air conditioning,
        /// or speech in a locale the installed model doesn't cover. That's the
        /// intended trade: a false positive costs one log line, a false negative
        /// cost 58 minutes of somebody's meeting.
        case signalWithoutTranscript
    }

    public let channel: SpeakerChannel
    /// Whether the channel's own signal test cleared its silence floor.
    ///
    /// For the mic that's `CapturePeakWatch`'s whole-recording peak against
    /// −60 dBFS; for the system tap it's `SilenceWatch`'s any-nonzero-sample test
    /// over the opening seconds. The asymmetry is why this only ever fires on
    /// *true*: the tap's window can miss a call that starts late, so `false` there
    /// isn't evidence of anything.
    public let carriedSignal: Bool
    /// The loudest linear sample the channel measured, when the channel measures
    /// levels at all. Nil for the system tap, whose watch answers yes/no.
    public let peak: Float?
    /// The capture format, as the device reported it — the fact that made issue
    /// #174 diagnosable, and the first thing to look at when this fires again. Nil
    /// only when the source never got far enough to learn it.
    public let format: CapturedAudioFormat?
    /// Finalized transcript segments this channel contributed to the meeting.
    public let segmentCount: Int

    public init(
        channel: SpeakerChannel,
        carriedSignal: Bool,
        peak: Float? = nil,
        format: CapturedAudioFormat? = nil,
        segmentCount: Int
    ) {
        self.channel = channel
        self.carriedSignal = carriedSignal
        self.peak = peak
        self.format = format
        self.segmentCount = segmentCount
    }

    public var verdict: Verdict {
        guard carriedSignal else { return .silentChannel }
        return segmentCount == 0 ? .signalWithoutTranscript : .consistent
    }

    /// What to log, at `.error`, when the verdict is the bug — nil otherwise, so a
    /// caller can log unconditionally on a non-nil result.
    public var diagnosis: String? {
        guard verdict == .signalWithoutTranscript else { return nil }
        return """
            The \(channel.rawValue) channel captured audio (\(peakDescription)) at \(formatDescription) \
            and produced no transcript at all. That is most often a transcription-path failure for this \
            format — check the conversion feeding SpeechAnalyzer first (issue #174 was a channel count \
            the converter silently mapped to nothing). It can also be honest: a room above the silence \
            floor where nobody said anything the model recognized, or speech in a locale it doesn't \
            cover. Whatever audio retention still keeps is the only copy of this half of the meeting.
            """
    }

    private var formatDescription: String {
        format?.description ?? "an unrecorded format"
    }

    private var peakDescription: String {
        guard let peak else { return "signal, level unmeasured" }
        return "peak \(CapturePeakWatch.Verdict(peak: peak).peakDescription)"
    }
}
