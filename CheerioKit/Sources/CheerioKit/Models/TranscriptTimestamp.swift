import Foundation

/// Sparse mm:ss orientation for a transcript, live or persisted.
///
/// `TranscriptSegment.startTime` and `TranscriptionUpdate.startTime` are both
/// already seconds-from-meeting-start (see those types' doc comments), so this
/// operates on a plain `TimeInterval` sequence rather than either model directly —
/// the live view's `TranscriptionUpdate` lines and the detail view's persisted
/// `TranscriptSegment`s can share one policy without either depending on the
/// other's type.
public enum TranscriptTimestamp {
    /// Which entries in a sequence of segment start times should carry a visible
    /// stamp: the first one, in array order, to land in each whole minute.
    ///
    /// Turn-taking can be a segment every 1-2s (see `docs/ARCHITECTURE.md`'s
    /// diarization verification), so stamping every segment — or even every speaker
    /// turn, which is nearly as dense in that data — would turn the transcript into
    /// a column of numbers instead of the quiet orientation issue #130 asked for.
    /// One stamp per elapsed minute stays sparse regardless of how choppy the
    /// conversation is, scales with meeting length rather than segment count, and
    /// gives issue #123's future tap-to-seek a fixed, low-density set of anchors —
    /// a scrubber's minute markers, not a timestamp per line.
    ///
    /// Deliberately tolerant of arrival order, not just chronological order: the
    /// live transcript's lines come from two independent per-channel consumer
    /// tasks (`CaptureSession.startCapturing`'s mic/system loop), each finalizing
    /// on its own schedule, so a mic line timestamped 61s can render before a
    /// system line timestamped 58s. Tracking *every minute already stamped*, rather
    /// than only comparing against the most recent one, keeps the "one stamp per
    /// minute" guarantee even when a later-arriving line's start time falls behind
    /// one that already rendered — a minute revisited out of order doesn't get a
    /// second stamp. The persisted, detail-view path happens to already hand this
    /// sorted (`MeetingDetailView.sortedSegments`), where this reduces to "the
    /// first segment of each minute," but nothing here assumes that.
    public static func markedIndices<S: Sequence>(startTimes: S) -> Set<Int>
    where S.Element == TimeInterval {
        var marked = Set<Int>()
        var stampedMinutes = Set<Int>()
        for (index, startTime) in startTimes.enumerated() {
            let minute = Int(startTime / 60)
            guard stampedMinutes.insert(minute).inserted else { continue }
            marked.insert(index)
        }
        return marked
    }

    /// `mm:ss`, or `h:mm:ss` once a meeting runs past an hour — the same shape a
    /// media scrubber uses, so it reads as "a place in the recording" rather than
    /// a duration or a wall-clock time.
    public static func format(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        guard hours > 0 else {
            return String(format: "%d:%02d", minutes, seconds)
        }
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
}
