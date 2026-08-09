import Foundation
import Testing

@testable import CheerioKit

@Suite struct SpeakerTimelineTests {
    private func meeting(_ lines: [(label: String, channel: SpeakerChannel, start: Double, end: Double)]) -> Meeting {
        let meeting = Meeting(title: "Standup")
        meeting.segments = lines.map { label, channel, start, end in
            let segment = TranscriptSegment(channel: channel, text: label, startTime: start, endTime: end)
            segment.speakerLabel = label
            return segment
        }
        return meeting
    }

    @Test func talkTimeProportionsSumToOne() {
        let m = meeting([
            ("Glen", .me, 0, 6),
            ("Speaker 1", .them, 6, 12),
            ("Speaker 1", .them, 12, 18),
        ])
        let talkTimes = m.speakerTalkTimes
        // Glen: 6s of 24s total; the two "Speaker 1" lines merge into one 12s summary.
        #expect(talkTimes.map(\.summary.label) == ["Speaker 1", "Glen"])
        #expect(talkTimes.map(\.proportion) == [12.0 / 18.0, 6.0 / 18.0])
        #expect(abs(talkTimes.reduce(0) { $0 + $1.proportion } - 1) < 0.0001)
    }

    @Test func talkTimeProportionIsZeroNotNaNWhenNobodyHasSpoken() {
        let m = Meeting(title: "Empty")
        #expect(m.speakerTalkTimes.isEmpty)

        // A segment that never resolves to any duration (start == end) still
        // produces a summary — the proportion for it must not divide by zero.
        let zeroLength = meeting([("Me", .me, 5, 5)])
        let talkTimes = zeroLength.speakerTalkTimes
        #expect(talkTimes.map(\.proportion) == [0])
    }

    @Test func talkTimeIDMatchesTheUnderlyingSummary() {
        let m = meeting([("Glen", .me, 0, 4)])
        #expect(m.speakerTalkTimes.map(\.id) == m.speakerSummaries.map(\.id))
    }

    @Test func timelineOrdersSpansChronologicallyAcrossChannels() {
        let m = meeting([
            ("Speaker 1", .them, 10, 12),
            ("Glen", .me, 0, 4),
            ("Glen", .me, 5, 8),
        ])
        let spans = m.speakerTimeline
        #expect(spans.map(\.start) == [0, 5, 10])
        #expect(spans.map(\.label) == ["Glen", "Glen", "Speaker 1"])
    }

    @Test func timelineKeysMatchSpeakerSlotAssignments() {
        let m = meeting([("Glen", .me, 0, 4)])
        let ownerNames = Set(["Glen"])
        let assignments = m.resolveSpeakerSlots(ownerNames: ownerNames)
        let span = m.speakerTimeline[0]
        #expect(assignments[span.speakerKey] != nil)
        #expect(assignments[span.speakerKey] == .you)
    }

    @Test func timelineDropsZeroAndNegativeLengthSpans() {
        let m = meeting([
            ("Glen", .me, 0, 4),
            ("Glen", .me, 6, 6),
            ("Glen", .me, 9, 8),
        ])
        #expect(m.speakerTimeline.map(\.start) == [0])
    }

    @Test func timelineIsEmptyForAMeetingWithNoTranscript() {
        let m = Meeting(title: "Silent")
        #expect(m.speakerTimeline.isEmpty)
    }
}
