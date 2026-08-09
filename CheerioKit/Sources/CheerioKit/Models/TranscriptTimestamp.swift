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
    /// Which entries in a chronologically-ordered sequence of segment start times
    /// should carry a visible stamp: the first one to land in a new whole minute.
    ///
    /// Turn-taking can be a segment every 1-2s (see `docs/ARCHITECTURE.md`'s
    /// diarization verification), so stamping every segment — or even every speaker
    /// turn, which is nearly as dense in that data — would turn the transcript into
    /// a column of numbers instead of the quiet orientation issue #130 asked for.
    /// One stamp per elapsed minute stays sparse regardless of how choppy the
    /// conversation is, scales with meeting length rather than segment count, and
    /// gives issue #123's future tap-to-seek a fixed, low-density set of anchors —
    /// a scrubber's minute markers, not a timestamp per line.
    public static func markedIndices<S: Sequence>(startTimes: S) -> Set<Int>
    where S.Element == TimeInterval {
        var marked = Set<Int>()
        var lastMarkedMinute = -1
        for (index, startTime) in startTimes.enumerated() {
            let minute = Int(startTime / 60)
            guard minute != lastMarkedMinute else { continue }
            marked.insert(index)
            lastMarkedMinute = minute
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
