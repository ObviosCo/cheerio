import Foundation
import SwiftData
import Testing

@testable import CheerioKit

/// Round-trips through a real on-disk store, because the properties these cover are
/// promises *about* the store: `stableID` claims to be process-independent, and
/// `kindRaw` claims existing rows migrate onto `.meeting`. An in-memory object can't
/// vouch for either — only writing, tearing down the container, and reopening can.
///
/// What this can't simulate is a store written by the *previous* schema: one process
/// gets one schema version. The backstop for that is `stableID`'s nil-tolerant design
/// (an old row reads as `uuid == nil`, which is exactly the state `reopen` verifies
/// backfill from) and the default on `kindRaw`, which SwiftData applies to rows that
/// predate the column.
@Suite struct MeetingPersistenceTests {
    /// A store in its own temp directory, torn down with the directory.
    private struct TempStore {
        let url: URL

        init() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cheerio-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("test.store")
        }

        func open() throws -> ModelContainer {
            try ModelContainer(
                for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
                configurations: ModelConfiguration(url: url)
            )
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    @Test func stableIDBackfillPersistsAcrossReopen() throws {
        let store = try TempStore()
        defer { store.tearDown() }

        // First "process": rows whose uuid is nil, the state a migrated legacy row is
        // in. Backfill via stableID, then save — the backfill is only as good as the
        // caller saving it, which is the contract this test pins.
        var firstID: UUID?
        var secondID: UUID?
        do {
            let container = try store.open()
            let context = ModelContext(container)
            let first = Meeting(title: "First")
            let second = Meeting(title: "Second")
            context.insert(first)
            context.insert(second)
            #expect(first.uuid == nil)
            firstID = first.stableID
            secondID = second.stableID
            try context.save()
        }

        // Second "process": a fresh container over the same file must read the same
        // identifiers back, distinct from each other.
        let container = try store.open()
        let context = ModelContext(container)
        let meetings = try context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.title)]))
        #expect(meetings.map(\.uuid) == [firstID, secondID])
        #expect(firstID != secondID)
    }

    @Test func kindSurvivesStoreReopen() throws {
        let store = try TempStore()
        defer { store.tearDown() }

        do {
            let container = try store.open()
            let context = ModelContext(container)
            let meeting = Meeting(title: "Standup")
            let directive = Meeting(title: "Talking to my agent")
            directive.kind = .directive
            context.insert(meeting)
            context.insert(directive)
            try context.save()
        }

        let container = try store.open()
        let context = ModelContext(container)
        let meetings = try context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.title)]))
        #expect(meetings.map(\.kind) == [.meeting, .directive])
    }
}
