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
}
