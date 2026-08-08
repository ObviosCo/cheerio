import Foundation
import SwiftData
import Testing

@testable import CheerioKit

/// Covers issue #32's two title rules: `isTitleAutomatic` migrates additively and
/// never lets auto-title clobber a calendar or human-chosen title, and
/// `TitleGenerator`'s deterministic post-processing around the model call.
@Suite struct MeetingTitleTests {
    // MARK: - isTitleAutomatic default and migration

    @Test func isTitleAutomaticDefaultsToFalse() {
        // A plain `Meeting(title:)` is what every existing call site (and every row
        // written before this property existed) produces — it must read as "someone
        // decided this title," not as an auto-title candidate, or a migrated store
        // would suddenly have every past meeting eligible for retitling.
        let meeting = Meeting(title: "Standup")
        #expect(meeting.isTitleAutomatic == false)
        #expect(meeting.shouldAutoTitle == false)
    }

    @Test func isTitleAutomaticSurvivesStoreReopen() throws {
        // Mirrors MeetingPersistenceTests' round-trip style: additive SwiftData
        // properties are only really pinned by writing, reopening, and reading them
        // back from a fresh container over the same file.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cheerio-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.store")

        func open() throws -> ModelContainer {
            try ModelContainer(
                for: Meeting.self, TranscriptSegment.self,
                configurations: ModelConfiguration(url: url)
            )
        }

        do {
            let container = try open()
            let context = ModelContext(container)
            let automatic = Meeting(title: "Meeting Aug 8, 2026 at 9:36 AM")
            automatic.isTitleAutomatic = true
            let manual = Meeting(title: "Cheerio pivot to actionable transcripts")
            context.insert(automatic)
            context.insert(manual)
            try context.save()
        }

        let container = try open()
        let context = ModelContext(container)
        let meetings = try context.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.title)]))
        let byTitle = Dictionary(uniqueKeysWithValues: meetings.map { ($0.title, $0) })
        #expect(byTitle["Meeting Aug 8, 2026 at 9:36 AM"]?.isTitleAutomatic == true)
        #expect(byTitle["Cheerio pivot to actionable transcripts"]?.isTitleAutomatic == false)
    }

    // MARK: - shouldAutoTitle / never-overwrite rules

    @Test func freshPlaceholderIsEligibleForAutoTitle() {
        let meeting = Meeting(title: "Meeting Aug 8, 2026 at 9:36 AM")
        meeting.isTitleAutomatic = true
        #expect(meeting.shouldAutoTitle)
    }

    @Test func calendarDerivedTitleIsNeverEligibleEvenIfFlaggedAutomatic() {
        // Defense-in-depth: `calendarEventID` is checked independently of
        // `isTitleAutomatic` so a bug that leaves the flag set can't cost the user a
        // title their calendar chose for them.
        let meeting = Meeting(title: "Design review", calendarEventID: "event-1")
        meeting.isTitleAutomatic = true
        #expect(meeting.shouldAutoTitle == false)
    }

    @Test func manualRenameRetiresIsTitleAutomaticPermanently() {
        let meeting = Meeting(title: "Meeting Aug 8, 2026 at 9:36 AM")
        meeting.isTitleAutomatic = true

        meeting.rename(to: "Cheerio pivot to actionable transcripts")

        #expect(meeting.title == "Cheerio pivot to actionable transcripts")
        #expect(meeting.isTitleAutomatic == false)
        #expect(meeting.shouldAutoTitle == false)
    }

    @Test func renamedTitleIsUntouchedByASubsequentGeneratedTitleAttempt() {
        // The scenario the "never overwrite" rule exists for: a user renames, then
        // something calls the auto-title path again later (a retry, a second
        // recording session). The gate must already have refused before this point,
        // but this pins that applying a generated title after a rename would be a
        // caller bug, not something `applyGeneratedTitle` silently protects against —
        // callers must check `shouldAutoTitle` first.
        let meeting = Meeting(title: "Meeting Aug 8, 2026 at 9:36 AM")
        meeting.isTitleAutomatic = true
        meeting.rename(to: "My renamed title")

        #expect(meeting.shouldAutoTitle == false)
    }

    @Test func generatedTitleKeepsIsTitleAutomaticSet() {
        // Unlike a rename, a generated title is still just the machine's best guess —
        // a later, better transcript could in principle retitle it again.
        let meeting = Meeting(title: "Meeting Aug 8, 2026 at 9:36 AM")
        meeting.isTitleAutomatic = true

        meeting.applyGeneratedTitle("Q3 roadmap review")

        #expect(meeting.title == "Q3 roadmap review")
        #expect(meeting.isTitleAutomatic == true)
        #expect(meeting.shouldAutoTitle == true)
    }

    // MARK: - TitleGenerator post-processing

    @Test func cleanTrimsSurroundingWhitespace() {
        #expect(TitleGenerator.clean("  Q3 roadmap review  \n") == "Q3 roadmap review")
    }

    @Test func cleanCollapsesEmbeddedNewlines() {
        #expect(TitleGenerator.clean("Q3 roadmap\nreview") == "Q3 roadmap review")
    }

    @Test func cleanStripsSurroundingStraightDoubleQuotes() {
        #expect(TitleGenerator.clean("\"Q3 roadmap review\"") == "Q3 roadmap review")
    }

    @Test func cleanStripsSurroundingStraightSingleQuotes() {
        #expect(TitleGenerator.clean("'Q3 roadmap review'") == "Q3 roadmap review")
    }

    @Test func cleanStripsSurroundingCurlyQuotes() {
        #expect(TitleGenerator.clean("“Q3 roadmap review”") == "Q3 roadmap review")
    }

    @Test func cleanLeavesAnInternalApostropheAlone() {
        // Only a matching pair at the very start and end counts as wrapping quotes —
        // a title that just happens to contain one apostrophe must survive intact.
        #expect(TitleGenerator.clean("Jackson's roadmap review") == "Jackson's roadmap review")
    }

    @Test func cleanDropsALoneTrailingPeriod() {
        #expect(TitleGenerator.clean("Q3 roadmap review.") == "Q3 roadmap review")
    }

    @Test func cleanClampsRunawayLength() {
        let raw = String(repeating: "a", count: 500)
        let cleaned = TitleGenerator.clean(raw)
        #expect(cleaned.count == TitleGenerator.maxTitleLength)
    }

    @Test func cleanHandlesQuotesAndTrailingPeriodTogether() {
        // Quote-stripping runs first and exposes the period underneath, which the
        // period-strip step then removes too.
        #expect(TitleGenerator.clean("\"Q3 roadmap review.\"") == "Q3 roadmap review")
    }
}
