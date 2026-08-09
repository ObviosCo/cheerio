import Foundation

/// A speaker's share of a meeting's talk, alongside the summary it's built from.
///
/// A sibling of ``SpeakerSummary`` rather than a field on it: `SpeakerSummary` is
/// one row in isolation, but a proportion only means anything against every other
/// speaker's total, so it can't be computed without seeing the whole meeting.
public struct SpeakerTalkTime: Identifiable, Sendable, Equatable {
    public let summary: SpeakerSummary
    /// This speaker's ``SpeakerSummary/duration`` divided by the sum of every
    /// speaker's duration in the meeting — not the meeting's wall-clock length, so
    /// two channels talking at once never pushes anyone's share past what they
    /// actually said. Zero (rather than NaN) when nobody has spoken yet.
    public let proportion: Double

    public var id: String { summary.id }
}

/// One chronological stretch of speech, coloured by whichever speaker it belongs
/// to — the raw material for a meeting-wide timeline.
///
/// Carries ``speakerKey`` rather than a resolved colour: colour only exists once
/// `SpeakerSlot` meets an actual `Color`, which happens in the app target (see
/// `Cheerio/Design/SpeakerIdentity.swift`), so this type stays free of SwiftUI and
/// buildable for the MCP helper and package tests like everything else here.
/// Carries plain values rather than a `TranscriptSegment` reference for the same
/// reason `SpeakerSummary` does: a SwiftData model isn't `Sendable`, and a render
/// pass over a meeting's whole transcript has no business holding one open.
public struct SpeakerTimelineSpan: Identifiable, Sendable, Equatable {
    public let id: String
    /// Matches ``SpeakerSummary/id`` and ``TranscriptSegment/speakerSlotKey`` — the
    /// key ``SpeakerSlotAssigner`` files this span's colour slot under.
    public let speakerKey: String
    public let label: String
    /// Seconds from meeting start, matching ``TranscriptSegment/startTime``.
    public let start: TimeInterval
    public let end: TimeInterval
}

extension Meeting {
    /// Per-speaker talk time, most talkative first (the same order
    /// ``speakerSummaries`` already sorts into).
    public var speakerTalkTimes: [SpeakerTalkTime] {
        let summaries = speakerSummaries
        let total = summaries.reduce(0) { $0 + $1.duration }
        return summaries.map { summary in
            SpeakerTalkTime(summary: summary, proportion: total > 0 ? summary.duration / total : 0)
        }
    }

    /// Every transcript segment across both channels, chronologically, as spans a
    /// timeline view can paint without touching a ``TranscriptSegment`` directly.
    ///
    /// Zero-or-negative-duration segments are dropped: a span with no width would
    /// only ever render as an invisible sliver, and `endTime < startTime` has
    /// shown up from a diarization edge case that's otherwise harmless to ignore.
    public var speakerTimeline: [SpeakerTimelineSpan] {
        segments
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
            .map { segment in
                SpeakerTimelineSpan(
                    id: "\(segment.speakerSlotKey)#\(segment.startTime)-\(segment.endTime)",
                    speakerKey: segment.speakerSlotKey,
                    label: segment.displayLabel,
                    start: segment.startTime,
                    end: segment.endTime
                )
            }
    }
}
