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
        try MeetingDeletion.delete(meeting, context: context) { path in
            removedPaths.append(path)
        }

        #expect(removedPaths == ["Meetings/abc-123"])
    }

    @Test func skipsAudioRemovalWhenNoDirectoryIsRecorded() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = nil
        context.insert(meeting)
        try context.save()

        var removeAudioCalled = false
        try MeetingDeletion.delete(meeting, context: context) { _ in
            removeAudioCalled = true
        }

        #expect(!removeAudioCalled)
    }

    @Test func deletesTheMeetingEvenWhenAudioRemovalFails() throws {
        struct RemovalFailure: Error {}
        let context = try makeContext()
        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = "Meetings/abc-123"
        context.insert(meeting)
        try context.save()

        try MeetingDeletion.delete(meeting, context: context) { _ in throw RemovalFailure() }

        #expect(try context.fetch(FetchDescriptor<Meeting>()).isEmpty)
    }
}
