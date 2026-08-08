import Testing

@testable import CheerioKit

/// `Meeting.isOwnerAttributed` is the mechanical half of the speaker-trust rule:
/// whether a transcript line is something the owner said, as opposed to a guest. It's
/// consumed unmodified by owner-attributed actions and the MCP server, so every case
/// that decides the answer needs to be pinned down here.
@Suite struct OwnerResolutionTests {
    private let ownerNames: Set<String> = ["Jackson"]

    @Test func undiarizedMicLineIsTheOwners() {
        let segment = TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 1)
        #expect(segment.speakerLabel == nil)
        #expect(Meeting.isOwnerAttributed(segment, ownerNames: ownerNames))
    }

    @Test func undiarizedSystemLineIsNotTheOwners() {
        let segment = TranscriptSegment(channel: .them, text: "hi", startTime: 0, endTime: 1)
        #expect(!Meeting.isOwnerAttributed(segment, ownerNames: ownerNames))
    }

    @Test func diarizerGeneratedLabelOnMicIsTheOwners() {
        let segment = TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 1)
        segment.speakerLabel = "Speaker 1"
        #expect(TranscriptSegment.isDiarizerGeneratedLabel(segment.speakerLabel))
        #expect(Meeting.isOwnerAttributed(segment, ownerNames: ownerNames))
    }

    @Test func diarizerGeneratedLabelOnSystemChannelIsNotTheOwners() {
        // "Speaker 1" on the system tap is scoped to that channel and isn't the owner —
        // you can't be on the far end of your own call.
        let segment = TranscriptSegment(channel: .them, text: "hi", startTime: 0, endTime: 1)
        segment.speakerLabel = "Speaker 1"
        #expect(!Meeting.isOwnerAttributed(segment, ownerNames: ownerNames))
    }

    @Test func enrolledOwnerLabelIsTheOwnersOnTheMicChannel() {
        let segment = TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 1)
        segment.speakerLabel = "Jackson"
        #expect(Meeting.isOwnerAttributed(segment, ownerNames: ownerNames))
    }

    @Test func enrolledOwnerLabelIsTheOwnersEvenOnTheSystemChannel() {
        // Diarization can put the owner's own voice echo on the system tap; the label
        // naming them is what matters, not which physical channel picked it up.
        let segment = TranscriptSegment(channel: .them, text: "hi", startTime: 0, endTime: 1)
        segment.speakerLabel = "Jackson"
        #expect(Meeting.isOwnerAttributed(segment, ownerNames: ownerNames))
    }

    @Test func enrolledNonOwnerLabelIsNeverTheOwnersEvenOnTheMicChannel() {
        // The case the rule exists for: a named guest talking on the mic (in-person
        // meeting) must never be credited to the owner just because of the channel.
        let segment = TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 1)
        segment.speakerLabel = "Carter"
        #expect(!Meeting.isOwnerAttributed(segment, ownerNames: ownerNames))
    }

    @Test func manualNonOwnerLabelIsNeverTheOwnersEvenOnTheMicChannel() {
        let segment = TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 1)
        segment.assignSpeaker("Carter")
        #expect(segment.isSpeakerLabelManual)
        #expect(!Meeting.isOwnerAttributed(segment, ownerNames: ownerNames))
    }

    @Test func noEnrolledOwnerMeansNoLabelOrChannelCanQualify() {
        // Degenerate but real: nobody has enrolled as "me" yet.
        let mic = TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 1)
        let named = TranscriptSegment(channel: .me, text: "hi", startTime: 0, endTime: 1)
        named.speakerLabel = "Jackson"

        // Mic-channel, undiarized still counts — owner resolution for the channel half
        // of the rule doesn't require an enrollment to exist.
        #expect(Meeting.isOwnerAttributed(mic, ownerNames: []))
        // But a label naming "Jackson" isn't credited if nobody enrolled is named that.
        #expect(!Meeting.isOwnerAttributed(named, ownerNames: []))
    }
}
