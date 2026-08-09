import Foundation
import SwiftData
import Testing

@testable import CheerioKit

/// In-memory throughout — the SwiftData half doesn't need a real file, and the
/// audio half is verified through the injected `removeAudio` closure rather than
/// `AudioStorage`'s real Application Support container, so this suite never writes
/// outside its own process.
@Suite struct MeetingDeletionTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @Test func deletingCascadesToTranscriptSegments() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Standup")
        let segment = TranscriptSegment(channel: .me, text: "Hello", startTime: 0, endTime: 1)
        segment.meeting = meeting
        meeting.segments = [segment]
        context.insert(meeting)
        context.insert(segment)
        try context.save()

        try MeetingDeletion.delete(
            meetingID: meeting.persistentModelID,
            container: container,
            removeAudio: { _ in }
        )

        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<Meeting>()).isEmpty)
        #expect(try verify.fetch(FetchDescriptor<TranscriptSegment>()).isEmpty)
    }

    @Test func removesAudioDirectoryWhenOneExists() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = "Meetings/abc-123"
        context.insert(meeting)
        try context.save()

        var removedPaths: [String] = []
        try MeetingDeletion.delete(
            meetingID: meeting.persistentModelID,
            container: container,
            removeAudio: { path in removedPaths.append(path) }
        )

        #expect(removedPaths == ["Meetings/abc-123"])
    }

    @Test func skipsAudioRemovalWhenNoDirectoryIsRecorded() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = nil
        context.insert(meeting)
        try context.save()

        var removeAudioCalled = false
        try MeetingDeletion.delete(
            meetingID: meeting.persistentModelID,
            container: container,
            removeAudio: { _ in removeAudioCalled = true }
        )

        #expect(!removeAudioCalled)
    }

    @Test func deletesTheMeetingEvenWhenAudioRemovalFailsAfterASuccessfulSave() throws {
        struct RemovalFailure: Error {}
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = "Meetings/abc-123"
        context.insert(meeting)
        try context.save()

        // Recording the order, not just the outcome: the model must be persisted
        // before audio removal is even attempted, not after.
        var order: [String] = []
        try MeetingDeletion.delete(
            meetingID: meeting.persistentModelID,
            container: container,
            save: { context in
                order.append("save")
                try context.save()
            },
            removeAudio: { _ in
                order.append("removeAudio")
                throw RemovalFailure()
            }
        )

        #expect(order == ["save", "removeAudio"])
        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<Meeting>()).isEmpty)
    }

    @Test func audioSurvivesWhenTheSaveFails() throws {
        struct SaveFailure: Error {}
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = "Meetings/abc-123"
        context.insert(meeting)
        try context.save()

        var removeAudioCalled = false
        #expect(throws: SaveFailure.self) {
            try MeetingDeletion.delete(
                meetingID: meeting.persistentModelID,
                container: container,
                save: { _ in throw SaveFailure() },
                removeAudio: { _ in removeAudioCalled = true }
            )
        }

        // Never reached: a failed save must not be followed by removing the audio
        // it was supposed to be safe to remove.
        #expect(!removeAudioCalled)
        // Rolled back, not half-deleted: the meeting is still there to retry against.
        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<Meeting>()).count == 1)
    }

    /// Pins the actual bug the isolated-context design fixes: a failed delete
    /// save must not cost anything else pending in a *different* context on the
    /// same container. `liveContext` here stands in for the app's shared context
    /// mid-recording, with a transcript segment inserted but not yet saved —
    /// exactly what `CaptureSession.handle` leaves pending until `stop()`. If
    /// `MeetingDeletion` ran its rollback against that shared context instead of
    /// a dedicated one, this insert would have been discarded along with the
    /// failed deletion.
    @Test func aFailedDeleteDoesNotDisturbUnsavedChangesInAnotherContext() throws {
        struct SaveFailure: Error {}
        let container = try makeContainer()

        let setupContext = ModelContext(container)
        let meeting = Meeting(title: "Standup")
        setupContext.insert(meeting)
        try setupContext.save()
        let meetingID = meeting.persistentModelID

        let liveContext = ModelContext(container)
        let inFlightMeeting = Meeting(title: "Live call")
        liveContext.insert(inFlightMeeting)
        let segment = TranscriptSegment(channel: .me, text: "hello", startTime: 0, endTime: 1)
        segment.meeting = inFlightMeeting
        liveContext.insert(segment)

        #expect(throws: SaveFailure.self) {
            try MeetingDeletion.delete(
                meetingID: meetingID,
                container: container,
                save: { _ in throw SaveFailure() }
            )
        }

        // Still pending in `liveContext`, untouched by the failed deletion
        // happening in its own separate context.
        #expect(try liveContext.fetch(FetchDescriptor<TranscriptSegment>()).count == 1)
    }

    @Test func deletingAMeetingThatNoLongerExistsIsANoOp() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        try context.save()
        let meetingID = meeting.persistentModelID
        context.delete(meeting)
        try context.save()

        // Already gone — a concurrent delete, most likely. Must not throw or crash.
        try MeetingDeletion.delete(meetingID: meetingID, container: container)
    }
}
