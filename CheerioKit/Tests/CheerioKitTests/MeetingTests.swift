import Testing
@testable import CheerioKit

@Suite struct MeetingTests {
    @Test func transcriptTextOrdersAndLabelsSegments() {
        let meeting = Meeting(title: "Test")
        let a = TranscriptSegment(channel: .them, text: "Hello Jackson", startTime: 5, endTime: 6)
        let b = TranscriptSegment(channel: .me, text: "Hey there", startTime: 1, endTime: 2)
        meeting.segments = [a, b]

        #expect(meeting.transcriptText == "[Me] Hey there\n[Them] Hello Jackson")
    }

    @Test func speakerChannelRoundTrips() {
        let segment = TranscriptSegment(channel: .me, text: "x", startTime: 0, endTime: 1)
        #expect(segment.channel == .me)
    }

    @Test func searchMatchesTitleCaseInsensitively() {
        let meeting = Meeting(title: "Quarterly Roadmap")
        #expect(meeting.matches("roadmap"))
        #expect(meeting.matches("QUARTERLY"))
        #expect(!meeting.matches("retrospective"))
    }

    @Test func searchMatchesNotesAndTranscript() {
        let meeting = Meeting(title: "Standup")
        meeting.roughNotes = "ask about the Helsinki contract"
        meeting.enhancedNotes = "## Summary\nDiscussed pricing."
        meeting.segments = [
            TranscriptSegment(channel: .them, text: "we should ship by Friday", startTime: 0, endTime: 1)
        ]

        #expect(meeting.matches("helsinki"))
        #expect(meeting.matches("pricing"))
        #expect(meeting.matches("ship by Friday"))
        #expect(!meeting.matches("budget"))
    }
}
