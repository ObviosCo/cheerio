import Foundation
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

    @Test func searchMatchesDiarizedSpeakerButNotChannelLabels() {
        let meeting = Meeting(title: "Standup")
        let named = TranscriptSegment(channel: .me, text: "morning", startTime: 0, endTime: 1)
        named.speakerLabel = "Carter"
        meeting.segments = [named]

        // Finding a meeting by who spoke in it is worth keeping.
        #expect(meeting.matches("carter"))
        // "Me"/"Them" are channel fallbacks, not content. Searching the rendered
        // transcript matched their "[Me] " prefix, so "me" hit every meeting.
        #expect(!meeting.matches("them"))
    }

    @Test func kindDefaultsToMeeting() {
        let meeting = Meeting(title: "Standup")
        #expect(meeting.kind == .meeting)
        #expect(meeting.kindRaw == "meeting")
    }

    @Test func kindRoundTripsThroughRawStorage() {
        let meeting = Meeting(title: "Talking to my agent")
        meeting.kind = .directive
        #expect(meeting.kindRaw == "directive")
        #expect(meeting.kind == .directive)
    }

    @Test func unrecognizedKindRawFallsBackToMeeting() {
        // Mirrors a store written by a future version with a case we don't know yet.
        let meeting = Meeting(title: "Standup")
        meeting.kindRaw = "some-future-kind"
        #expect(meeting.kind == .meeting)
    }

    @Test func toggleKindFlipsMeetingToDirective() {
        let meeting = Meeting(title: "Standup")
        meeting.toggleKind()
        #expect(meeting.kind == .directive)
        #expect(meeting.kindRaw == "directive")
    }

    @Test func toggleKindFlipsDirectiveBackToMeeting() {
        let meeting = Meeting(title: "Talking to my agent")
        meeting.kind = .directive
        meeting.toggleKind()
        #expect(meeting.kind == .meeting)
    }

    @Test func toggleKindIsItsOwnInverse() {
        let meeting = Meeting(title: "Standup")
        meeting.toggleKind()
        meeting.toggleKind()
        #expect(meeting.kind == .meeting)
    }

    @Test func toggleKindTouchesNothingElse() {
        // Conversion is mechanical (issue #107) — it must not clear notes, action
        // items, or the transcript, even though the "other kind's prompt" concern
        // the PR discusses is about future divergence, not anything read back here.
        let meeting = Meeting(title: "Standup")
        meeting.enhancedNotes = "## Summary\nAll good."
        meeting.actionItems = [ActionItem(text: "Send the recap", isOwner: true, disposition: .actionable)]
        let segment = TranscriptSegment(channel: .me, text: "Morning", startTime: 0, endTime: 1)
        meeting.segments = [segment]

        meeting.toggleKind()

        #expect(meeting.enhancedNotes == "## Summary\nAll good.")
        #expect(meeting.actionItems.count == 1)
        #expect(meeting.segments.count == 1)
    }

    @Test func stableIDBackfillsDistinctValuesOnAccess() {
        // Simulates two meetings that already existed in the store when `uuid` was
        // added: both start nil, as a lightweight-migrated row would.
        let first = Meeting(title: "First")
        let second = Meeting(title: "Second")
        #expect(first.uuid == nil)
        #expect(second.uuid == nil)

        let firstID = first.stableID
        let secondID = second.stableID

        // The bug this guards against: a non-optional `UUID` default filling every
        // migrated row with the *same* generated value.
        #expect(firstID != secondID)
        #expect(first.uuid == firstID)
        #expect(second.uuid == secondID)
    }

    @Test func stableIDIsIdempotent() {
        let meeting = Meeting(title: "Standup")
        let first = meeting.stableID
        let second = meeting.stableID
        #expect(first == second)
    }

    @Test func stableIDLeavesAnAlreadySetUUIDAlone() {
        let meeting = Meeting(title: "Standup")
        let existing = UUID()
        meeting.uuid = existing
        #expect(meeting.stableID == existing)
    }
}
