import Foundation
import SwiftData
import Testing

@testable import CheerioKit

/// The migration gate. Opens a store **created by the v26.8.9 release schema**
/// (a committed synthetic fixture — one meeting, one segment, nobody's real
/// data) with the current schema, exactly what happens on a user's Mac the
/// first launch after an update.
///
/// This exists because 26.8.10 crashed at launch for every upgrading user:
/// `speakerSlotAssigner` was added as a non-optional Codable struct, SwiftData
/// flattened it into mandatory sub-attributes, the Swift-side default never
/// became a store-level default, and lightweight migration died with
/// "missing attribute values on mandatory destination attribute" before
/// `CheerioApp.init` fatalErrored. The schema metadata can't warn about this —
/// the pre-fix attribute *showed* a defaultValue — so the only honest test is
/// a real old store. When the schema changes again, this fixture stays as-is;
/// add a new fixture per released schema era if migration paths multiply.
@Suite struct StoreMigrationTests {
    @Test func aStoreFromThePreviousReleaseOpensAndMigrates() throws {
        let fixture = try #require(
            Bundle.module.url(
                forResource: "store-created-by-v26.8.9", withExtension: "store",
                subdirectory: "Fixtures"
            )
        )
        // Copy out of the bundle: migration rewrites the file in place.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let storeURL = scratch.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: fixture, to: storeURL)

        let container = try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let context = ModelContext(container)
        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        #expect(meetings.count == 1)
        let meeting = try #require(meetings.first)
        #expect(meeting.title == "Fixture meeting")
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSegment>()) == 1)
        // The migrated row's new field reads through the facade as empty, and
        // writing through it persists — proven by reopening the store in a
        // fresh container, not by re-reading the same tracked object.
        #expect(meeting.speakerSlotAssigner.assignments.isEmpty)
        var assigner = meeting.speakerSlotAssigner
        _ = assigner.slot(for: "fixture-speaker", isYou: false)
        meeting.speakerSlotAssigner = assigner
        try context.save()

        let reopened = try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let freshContext = ModelContext(reopened)
        let reloaded = try #require(try freshContext.fetch(FetchDescriptor<Meeting>()).first)
        #expect(reloaded.speakerSlotAssigner.assignments.count == 1)
    }

    /// The facade must round-trip through the optional storage on a fresh model
    /// too, not only on a migrated row.
    @Test func speakerSlotAssignerFacadeReadsAndWrites() {
        let meeting = Meeting(title: "Migration facade", startedAt: .now)
        #expect(meeting.speakerSlotAssigner.assignments.isEmpty)
        var assigner = SpeakerSlotAssigner()
        _ = assigner.slot(for: "alice", isYou: false)
        meeting.speakerSlotAssigner = assigner
        #expect(meeting.speakerSlotAssigner.assignments.count == 1)
    }
}
