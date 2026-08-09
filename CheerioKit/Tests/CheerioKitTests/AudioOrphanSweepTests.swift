import Foundation
import SwiftData
import Testing

@testable import CheerioKit

/// Entirely off `AudioStorage`'s real Application Support container — every test
/// points `sweep(context:meetingsDirectory:)` at its own temp directory instead.
@Suite struct AudioOrphanSweepTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// A `Meetings/` directory in its own temp root, torn down with it.
    private func makeMeetingsRoot() throws -> URL {
        let root = URL.temporaryDirectory
            .appending(path: "cheerio-orphan-sweep-\(UUID().uuidString)")
            .appending(path: "Meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func removesADirectoryNoLiveMeetingPointsAt() throws {
        let context = try makeContext()
        let root = try makeMeetingsRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let owned = UUID().uuidString
        let orphaned = UUID().uuidString
        try FileManager.default.createDirectory(
            at: root.appending(path: owned), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appending(path: orphaned), withIntermediateDirectories: true)

        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = "Meetings/\(owned)"
        context.insert(meeting)
        try context.save()

        let removed = try AudioOrphanSweep.sweep(context: context) { root }

        #expect(removed == 1)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: owned).path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: orphaned).path))
    }

    @Test func leavesEntriesThatDoNotLookLikeAMeetingDirectoryAlone() throws {
        let context = try makeContext()
        let root = try makeMeetingsRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        // Not a UUID name — not something `AudioStorage.makeMeetingDirectory()`
        // could have written, so the sweep has no business judging it.
        let notAMeetingDirectory = root.appending(path: "not-a-meeting-directory")
        try FileManager.default.createDirectory(
            at: notAMeetingDirectory, withIntermediateDirectories: true)
        // A UUID-named *file*, not a directory — also left alone.
        let strayFile = root.appending(path: UUID().uuidString)
        try Data().write(to: strayFile)

        let removed = try AudioOrphanSweep.sweep(context: context) { root }

        #expect(removed == 0)
        #expect(FileManager.default.fileExists(atPath: notAMeetingDirectory.path))
        #expect(FileManager.default.fileExists(atPath: strayFile.path))
    }

    @Test func aMissingMeetingsFolderIsNotAnError() throws {
        let context = try makeContext()
        let root = URL.temporaryDirectory.appending(path: "cheerio-orphan-sweep-missing-\(UUID().uuidString)")

        let removed = try AudioOrphanSweep.sweep(context: context) { root }

        #expect(removed == 0)
    }

    @Test func removesNothingWhenEveryDirectoryIsOwned() throws {
        let context = try makeContext()
        let root = try makeMeetingsRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let owned = UUID().uuidString
        try FileManager.default.createDirectory(
            at: root.appending(path: owned), withIntermediateDirectories: true)
        let meeting = Meeting(title: "Standup")
        meeting.audioDirectory = "Meetings/\(owned)"
        context.insert(meeting)
        try context.save()

        let removed = try AudioOrphanSweep.sweep(context: context) { root }

        #expect(removed == 0)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: owned).path))
    }
}
