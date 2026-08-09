import Foundation
import SwiftData
import Testing

@testable import CheerioKit

/// In-memory throughout — the SwiftData half doesn't need a real file, and the
/// audio half is verified through the injected `removeAudio` closure rather than
/// `AudioStorage`'s real Application Support container, so this suite never writes
/// outside its own process.
@Suite struct MeetingDeletionTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func deletingCascadesToTranscriptSegments() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Standup")
        let segment = TranscriptSegment(channel: .me, text: "Hello", startTime: 0, endTime: 1)
        segment.meeting = meeting
        meeting.segments = [segment]
        context.insert(meeting)
        context.insert(segment)
        try context.save()

        try MeetingDeletion.delete(meeting, context: context, removeAudio: { _ in })

        #expect(try context.fetch(FetchDescriptor<Meeting>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TranscriptSegment>()).isEmpty)
    }

    @Test func removesAudioDirectoryWhenOneExists() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = "Meetings/abc-123"
        context.insert(meeting)
        try context.save()

        var removedPaths: [String] = []
        try MeetingDeletion.delete(
            meeting,
            context: context,
            removeAudio: { path in removedPaths.append(path) }
        )

        #expect(removedPaths == ["Meetings/abc-123"])
    }

    @Test func skipsAudioRemovalWhenNoDirectoryIsRecorded() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = nil
        context.insert(meeting)
        try context.save()

        var removeAudioCalled = false
        try MeetingDeletion.delete(
            meeting,
            context: context,
            removeAudio: { _ in removeAudioCalled = true }
        )

        #expect(!removeAudioCalled)
    }

    @Test func deletesTheMeetingEvenWhenAudioRemovalFailsAfterASuccessfulSave() throws {
        struct RemovalFailure: Error {}
        let context = try makeContext()
        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = "Meetings/abc-123"
        context.insert(meeting)
        try context.save()

        // Recording the order, not just the outcome — this is the ordering the
        // review comment on the original version flagged: the model must be
        // persisted before audio removal is even attempted, not after.
        var order: [String] = []
        try MeetingDeletion.delete(
            meeting,
            context: context,
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
        #expect(try context.fetch(FetchDescriptor<Meeting>()).isEmpty)
    }

    @Test func audioSurvivesWhenTheSaveFails() throws {
        struct SaveFailure: Error {}
        let context = try makeContext()
        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = "Meetings/abc-123"
        context.insert(meeting)
        try context.save()

        var removeAudioCalled = false
        #expect(throws: SaveFailure.self) {
            try MeetingDeletion.delete(
                meeting,
                context: context,
                save: { _ in throw SaveFailure() },
                removeAudio: { _ in removeAudioCalled = true }
            )
        }

        // Never reached: a failed save must not be followed by removing the audio
        // it was supposed to be safe to remove.
        #expect(!removeAudioCalled)
        // Rolled back, not half-deleted: the meeting is still there to retry against.
        #expect(try context.fetch(FetchDescriptor<Meeting>()).count == 1)
    }
}
