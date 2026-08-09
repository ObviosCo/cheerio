import Foundation
import SwiftData
import Testing

@testable import CheerioKit

/// The bundled MCP helper's behaviour (issue #28), all of it.
///
/// The executable in `Cheerio.app` is protocol plumbing over
/// ``MeetingQueryService/handle(tool:arguments:)``, which is why these tests can cover
/// the tools without a transport: they hand the same JSON a `tools/call` would and
/// read back the same JSON the helper puts in a text content block.
@Suite struct MeetingMCPTests {
    // MARK: - Fixtures

    /// A store with a small, deliberately awkward history: a finished meeting, a
    /// directive, a recording in progress, and a legacy row with no `uuid`.
    private struct Fixture {
        let container: ModelContainer
        let service: MeetingQueryService
        let standup: UUID
        let directive: UUID
        let inProgress: UUID

        init() throws {
            container = try ModelContainer(
                for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let context = ModelContext(container)

            let me = EnrolledSpeaker(name: "Jackson", audioPath: "Speakers/me.caf", duration: 40)
            me.isMe = true
            context.insert(me)

            let standupMeeting = Fixture.make(
                title: "Standup", startedAt: "2026-08-05T09:00:00Z", endedAt: "2026-08-05T09:20:00Z")
            standupMeeting.roughNotes = "roadmap"
            standupMeeting.enhancedNotes = "## Summary\nShipping Friday."
            standupMeeting.actionItems = [
                ActionItem(text: "Update the roadmap", isOwner: true, disposition: .actionable),
                ActionItem(text: "Send the contract", owner: "Carter", isOwner: false, disposition: .followUp),
            ]
            let mine = TranscriptSegment(channel: .me, text: "Morning", startTime: 0, endTime: 5)
            let carter = TranscriptSegment(channel: .them, text: "Let's ship Friday", startTime: 5, endTime: 10)
            carter.speakerLabel = "Carter"
            standupMeeting.segments = [mine, carter]
            context.insert(standupMeeting)
            standup = standupMeeting.stableID

            let directiveMeeting = Fixture.make(
                title: "Notes for my agent", startedAt: "2026-08-06T11:00:00Z", endedAt: "2026-08-06T11:05:00Z")
            directiveMeeting.kind = .directive
            directiveMeeting.segments = [
                TranscriptSegment(channel: .me, text: "Refactor the tap", startTime: 0, endTime: 4)
            ]
            context.insert(directiveMeeting)
            directive = directiveMeeting.stableID

            // Still recording: no endedAt, no notes, a partial transcript.
            let live = Fixture.make(title: "Design review", startedAt: "2026-08-07T15:00:00Z", endedAt: nil)
            live.segments = [TranscriptSegment(channel: .me, text: "so far so good", startTime: 0, endTime: 3)]
            context.insert(live)
            inProgress = live.stableID

            // Written before `uuid` existed. Untouched by `stableID`, so it stays nil —
            // which is exactly the state the read-only helper has to cope with.
            let legacy = Fixture.make(title: "Ancient history", startedAt: "2025-01-02T08:00:00Z", endedAt: "2025-01-02T08:30:00Z")
            context.insert(legacy)

            try context.save()
            service = MeetingQueryService(container: container)
        }

        static func make(title: String, startedAt: String, endedAt: String?) -> Meeting {
            let iso = ISO8601DateFormatter()
            let meeting = Meeting(title: title, startedAt: iso.date(from: startedAt)!)
            meeting.endedAt = endedAt.flatMap(iso.date(from:))
            return meeting
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try MeetingQueryCoding.decoder().decode(type, from: data)
    }

    // MARK: - The tool surface

    @Test func everyToolDeclaresAWellFormedSchema() throws {
        for tool in MeetingMCPTool.allCases {
            #expect(!tool.description.isEmpty)
            let data = Data(tool.inputSchema.utf8)
            // Interpolated fragments make these schemas the one thing here a typo can
            // break silently, so parse every one rather than trusting the literals.
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let schema = try #require(parsed, "\(tool.rawValue)'s schema isn't a JSON object")
            #expect(schema["type"] as? String == "object")
            #expect(schema["additionalProperties"] as? Bool == false)
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(!properties.isEmpty)
        }
    }

    @Test func schemasNameTheArgumentsTheRequestsActuallyDecode() throws {
        // A schema promising a key the request struct doesn't read is a tool that
        // ignores what it was asked; the reverse is a capability no caller can find.
        func properties(of tool: MeetingMCPTool) throws -> Set<String> {
            let schema = try JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8)) as? [String: Any]
            return Set((schema?["properties"] as? [String: Any])?.keys ?? [:].keys)
        }
        #expect(try properties(of: .listMeetings) == ["kind", "since", "until", "limit", "offset"])
        #expect(try properties(of: .searchMeetings) == ["query", "kind", "since", "until", "limit", "offset"])
        for tool in [MeetingMCPTool.getMeeting, .getTranscript, .getActionItems] {
            #expect(try properties(of: tool) == ["uuid"])
        }
    }

    @Test func toolNamesAreStable() {
        // These are what a client's config and an agent's prompt refer to; renaming one
        // is a breaking change, so make it show up as a failing test.
        #expect(
            Set(MeetingMCPTool.allCases.map(\.rawValue)) == [
                "list_meetings", "get_meeting", "get_transcript", "search_meetings", "get_action_items",
            ])
    }

    // MARK: - list_meetings

    @Test func listReturnsNewestFirstAndMarksTheRecordingInProgress() async throws {
        let fixture = try Fixture()
        let page = try await fixture.service.list(ListMeetingsRequest())

        #expect(page.total == 4)
        #expect(page.meetings.map(\.title) == ["Design review", "Notes for my agent", "Standup", "Ancient history"])
        #expect(page.meetings.map(\.isInProgress) == [true, false, false, false])
        #expect(!page.hasMore)

        let live = try #require(page.meetings.first)
        #expect(live.endedAt == nil)
        #expect(live.segmentCount == 1)
        #expect(!live.hasEnhancedNotes)
        #expect(live.actionItemCount == 0)
    }

    @Test func listPages() async throws {
        let fixture = try Fixture()
        let first = try await fixture.service.list(ListMeetingsRequest(limit: 2))
        #expect(first.meetings.map(\.title) == ["Design review", "Notes for my agent"])
        #expect(first.total == 4)
        #expect(first.hasMore)

        let second = try await fixture.service.list(ListMeetingsRequest(limit: 2, offset: 2))
        #expect(second.meetings.map(\.title) == ["Standup", "Ancient history"])
        #expect(!second.hasMore)

        // Past the end is an empty page, not an error.
        let past = try await fixture.service.list(ListMeetingsRequest(limit: 2, offset: 99))
        #expect(past.meetings.isEmpty)
        #expect(past.total == 4)
        #expect(!past.hasMore)
    }

    @Test func listClampsAbsurdLimits() async throws {
        let fixture = try Fixture()
        #expect(try await fixture.service.list(ListMeetingsRequest(limit: 100_000)).limit == MeetingQueryService.maximumLimit)
        #expect(try await fixture.service.list(ListMeetingsRequest(limit: 0)).limit == 1)
        #expect(try await fixture.service.list(ListMeetingsRequest(offset: -5)).offset == 0)
    }

    @Test func listFiltersByKindAndDate() async throws {
        let fixture = try Fixture()
        let iso = ISO8601DateFormatter()

        let directives = try await fixture.service.list(ListMeetingsRequest(kind: .directive))
        #expect(directives.meetings.map(\.title) == ["Notes for my agent"])
        #expect(directives.total == 1)

        // `since` is inclusive, `until` exclusive — the standup starts exactly on both
        // bounds here, so this pins which way each one goes.
        let window = try await fixture.service.list(
            ListMeetingsRequest(
                since: iso.date(from: "2026-08-05T09:00:00Z")!,
                until: iso.date(from: "2026-08-06T11:00:00Z")!))
        #expect(window.meetings.map(\.title) == ["Standup"])
    }

    // MARK: - search_meetings

    @Test func searchUsesTheAppsOwnMatchSemantics() async throws {
        let fixture = try Fixture()

        // Transcript text, a speaker's name, the enhanced notes, the rough notes: the
        // four places `Meeting.matches` looks that a title search wouldn't.
        #expect(try await fixture.service.search(SearchMeetingsRequest(query: "ship friday")).meetings.map(\.title) == ["Standup"])
        #expect(try await fixture.service.search(SearchMeetingsRequest(query: "carter")).meetings.map(\.title) == ["Standup"])
        #expect(try await fixture.service.search(SearchMeetingsRequest(query: "roadmap")).meetings.map(\.title) == ["Standup"])
        #expect(try await fixture.service.search(SearchMeetingsRequest(query: "refactor")).meetings.map(\.title) == ["Notes for my agent"])
        #expect(try await fixture.service.search(SearchMeetingsRequest(query: "nothing here")).meetings.isEmpty)
    }

    @Test func searchCombinesWithTheListFiltersAndPaging() async throws {
        let fixture = try Fixture()
        let filtered = try await fixture.service.search(SearchMeetingsRequest(query: "the", kind: .directive))
        #expect(filtered.meetings.map(\.title) == ["Notes for my agent"])
    }

    @Test func searchRejectsABlankQuery() async throws {
        let fixture = try Fixture()
        // Not "everything": a blank query means the caller lost track of its own
        // arguments, and answering it with the whole store hides that.
        await #expect(throws: MeetingQueryService.Failure.invalidArguments(tool: .searchMeetings, detail: "query was empty")) {
            try await fixture.service.search(SearchMeetingsRequest(query: "   "))
        }
    }

    // MARK: - get_meeting / get_transcript / get_action_items

    @Test func getMeetingReturnsTheSameExportTheCallbackSends() async throws {
        let fixture = try Fixture()
        let export = try await fixture.service.export(for: fixture.standup)

        #expect(export.uuid == fixture.standup)
        #expect(export.title == "Standup")
        #expect(export.kind == .meeting)
        #expect(export.enhancedNotes == "## Summary\nShipping Friday.")
        #expect(export.segments.map(\.displayLabel) == ["Me", "Carter"])
        #expect(export.segments.map(\.isOwner) == [true, false])
        #expect(export.actionItems.map(\.text) == ["Update the roadmap", "Send the contract"])
    }

    @Test func transcriptAndActionItemsAreSubsetsOfTheExport() async throws {
        let fixture = try Fixture()
        let export = try await fixture.service.export(for: fixture.standup)

        let transcript = TranscriptResult(export: export)
        #expect(transcript.segments == export.segments)
        #expect(transcript.uuid == export.uuid)
        #expect(!transcript.isInProgress)

        let items = ActionItemsResult(export: export)
        #expect(items.actionItems == export.actionItems)
    }

    @Test func transcriptOfALiveRecordingIsReadableAndSaysSo() async throws {
        let fixture = try Fixture()
        let transcript = TranscriptResult(export: try await fixture.service.export(for: fixture.inProgress))
        #expect(transcript.isInProgress)
        #expect(transcript.segments.map(\.text) == ["so far so good"])
    }

    @Test func actionItemsAreReconciledSoStaleIdentityCantLeak() async throws {
        let fixture = try Fixture()
        // Relabel the owner's only line onto a guest, without re-running enhancement —
        // the persisted item still claims `actionable`. Reading it over MCP must not.
        let context = ModelContext(fixture.container)
        let meeting = try #require(
            try context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.title == "Standup" })).first)
        for segment in meeting.segments where segment.channel == .me {
            segment.assignSpeaker("Carter")
        }
        try context.save()

        let items = ActionItemsResult(export: try await MeetingQueryService(container: fixture.container).export(for: fixture.standup))
        #expect(items.actionItems.map(\.disposition) == [.followUp, .followUp])
    }

    @Test func anUnknownIDIsAPoliteFailure() async throws {
        let fixture = try Fixture()
        let missing = UUID()
        await #expect(throws: MeetingQueryService.Failure.noSuchMeeting(uuid: missing)) {
            try await fixture.service.export(for: missing)
        }
        #expect(MeetingQueryService.Failure.noSuchMeeting(uuid: missing).description.contains("open Cheerio once"))
    }

    // MARK: - Legacy rows with no uuid

    @Test func aMeetingWithoutAnIDIsListedWithAnExplanationRatherThanHidden() async throws {
        let fixture = try Fixture()
        let page = try await fixture.service.list(ListMeetingsRequest())
        let legacy = try #require(page.meetings.first { $0.title == "Ancient history" })

        #expect(legacy.uuid == nil)
        let reason = try #require(legacy.unavailable)
        #expect(reason.contains("no identifier yet"))
        // Its neighbours carry no such note.
        #expect(page.meetings.filter { $0.unavailable != nil }.count == 1)
    }

    @Test func readingALegacyRowNeverMintsAnIdentifier() async throws {
        let fixture = try Fixture()
        // The trap this guards: `MeetingExport`'s ordinary initializer reads
        // `stableID`, which *assigns* uuid — a write, from a process that opened the
        // store read-only. Listing and searching must go nowhere near it.
        _ = try await fixture.service.list(ListMeetingsRequest())
        _ = try await fixture.service.search(SearchMeetingsRequest(query: "ancient"))

        let context = ModelContext(fixture.container)
        let legacy = try #require(
            try context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.title == "Ancient history" })).first)
        #expect(legacy.uuid == nil)
        #expect(legacy.readOnlyExport(ownerNames: []) == nil)
    }

    @Test func theAppBackfillsWhatTheHelperCantAndDoesItOnce() throws {
        let fixture = try Fixture()
        let context = ModelContext(fixture.container)

        #expect(StorageMigration.backfillMeetingIDs(context: context) == 1)
        let legacy = try #require(
            try context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.title == "Ancient history" })).first)
        let assigned = try #require(legacy.uuid)
        #expect(legacy.readOnlyExport(ownerNames: [])?.uuid == assigned)

        // Idempotent, and it doesn't reassign what it already did.
        #expect(StorageMigration.backfillMeetingIDs(context: context) == 0)
        #expect(legacy.uuid == assigned)
    }

    // MARK: - Dispatch through the JSON boundary

    @Test func handleDispatchesEveryToolOverJSON() async throws {
        let fixture = try Fixture()
        let id = #"{"uuid":"\#(fixture.standup.uuidString)"}"#

        let listed = try await fixture.service.handle(tool: .listMeetings, arguments: Data(#"{"limit":1}"#.utf8))
        #expect(try Self.decode(MeetingPage.self, from: listed).meetings.count == 1)

        let searched = try await fixture.service.handle(tool: .searchMeetings, arguments: Data(#"{"query":"roadmap"}"#.utf8))
        #expect(try Self.decode(MeetingPage.self, from: searched).total == 1)

        let got = try await fixture.service.handle(tool: .getMeeting, arguments: Data(id.utf8))
        #expect(try Self.decode(MeetingExport.self, from: got).title == "Standup")

        let transcript = try await fixture.service.handle(tool: .getTranscript, arguments: Data(id.utf8))
        #expect(try Self.decode(TranscriptResult.self, from: transcript).segments.count == 2)

        let items = try await fixture.service.handle(tool: .getActionItems, arguments: Data(id.utf8))
        #expect(try Self.decode(ActionItemsResult.self, from: items).actionItems.count == 2)
    }

    @Test func pagingFieldsSurviveEncoding() async throws {
        let fixture = try Fixture()
        // `hasMore` was a computed property once, which `Codable` silently drops — so
        // the key `list_meetings`' own description tells callers to check wasn't in the
        // JSON at all. Assert on the encoded form, not the Swift value.
        let data = try await fixture.service.handle(tool: .listMeetings, arguments: Data(#"{"limit":2}"#.utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["meetings", "total", "offset", "limit", "hasMore"])
        #expect(json["hasMore"] as? Bool == true)
        #expect(json["total"] as? Int == 4)
    }

    @Test func omittedArgumentsMeanTheDefaults() async throws {
        let fixture = try Fixture()
        // MCP clients omit `arguments` entirely for a tool with no required fields, and
        // an empty body must not read as malformed JSON.
        for body in ["", "{}"] {
            let data = try await fixture.service.handle(tool: .listMeetings, arguments: Data(body.utf8))
            let page = try Self.decode(MeetingPage.self, from: data)
            #expect(page.limit == MeetingQueryService.defaultLimit)
            #expect(page.total == 4)
        }
    }

    @Test func badArgumentsComeBackReadable() async throws {
        let fixture = try Fixture()

        // A missing required key names the key.
        do {
            _ = try await fixture.service.handle(tool: .getMeeting, arguments: Data("{}".utf8))
            Issue.record("expected a failure")
        } catch let failure as MeetingQueryService.Failure {
            #expect(failure.description == "Couldn't read the arguments to get_meeting: “uuid” is required")
        }

        // A malformed uuid says which argument, not which Swift type couldn't be built.
        do {
            _ = try await fixture.service.handle(tool: .getMeeting, arguments: Data(#"{"uuid":"not-a-uuid"}"#.utf8))
            Issue.record("expected a failure")
        } catch let failure as MeetingQueryService.Failure {
            #expect(failure.description.contains("uuid"))
        }

        // An unrecognized kind is a failure rather than being silently ignored.
        await #expect(throws: MeetingQueryService.Failure.self) {
            try await fixture.service.handle(tool: .listMeetings, arguments: Data(#"{"kind":"standup"}"#.utf8))
        }
    }

    @Test func resultsUseTheExportsOwnEncoding() async throws {
        let fixture = try Fixture()
        let data = try await fixture.service.handle(tool: .getMeeting, arguments: Data(#"{"uuid":"\#(fixture.standup.uuidString)"}"#.utf8))
        let json = String(decoding: data, as: UTF8.self)
        // ISO 8601 dates and sorted keys, i.e. byte-identical to what the
        // transcript-ready callback writes for the same meeting.
        #expect(json.contains(#""startedAt":"2026-08-05T09:00:00Z""#))
        #expect(json.hasPrefix(#"{"actionItems":"#))
    }

    @Test func summaryFieldsAreSpelledTheSameAsTheExports() async throws {
        let fixture = try Fixture()
        // `MeetingSummary` claims to be a subset of `MeetingExport`. Anything it adds
        // has to be a genuinely list-only concern, not a second spelling of a field the
        // export already has.
        // The standup specifically, and via search so it's the only match: a summary of
        // the *in-progress* meeting would be missing `endedAt` because it's nil, and
        // absent-because-nil isn't the mismatch this test is looking for.
        let page = try await fixture.service.handle(tool: .searchMeetings, arguments: Data(#"{"query":"roadmap"}"#.utf8))
        let summary = try #require(
            (try JSONSerialization.jsonObject(with: page) as? [String: Any])?["meetings"] as? [[String: Any]])
        let summaryKeys = Set(try #require(summary.first).keys)

        let export = try await fixture.service.handle(
            tool: .getMeeting, arguments: Data(#"{"uuid":"\#(fixture.standup.uuidString)"}"#.utf8))
        let exportKeys = Set(try #require(try JSONSerialization.jsonObject(with: export) as? [String: Any]).keys)

        #expect(summaryKeys.subtracting(exportKeys) == ["isInProgress", "segmentCount", "hasEnhancedNotes", "actionItemCount"])
        #expect(exportKeys.subtracting(summaryKeys) == ["roughNotes", "enhancedNotes", "segments", "actionItems"])
    }

    // MARK: - Argument dates

    @Test func datesAcceptWhatAModelIsLikelyToType() throws {
        let iso = ISO8601DateFormatter()
        #expect(MeetingQueryCoding.parseDate("2026-08-05T09:00:00Z") == iso.date(from: "2026-08-05T09:00:00Z"))
        #expect(MeetingQueryCoding.parseDate("2026-08-05T09:00:00.500Z") != nil)
        // A bare date, read in the caller's own time zone — "since August 5th" means
        // their August 5th, not UTC's.
        let day = try #require(MeetingQueryCoding.parseDate("2026-08-05"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        #expect(calendar.dateComponents([.year, .month, .day], from: day) == DateComponents(year: 2026, month: 8, day: 5))
        #expect(MeetingQueryCoding.parseDate("last Tuesday") == nil)
    }

    // MARK: - Opening the store

    @Test func aMissingStoreIsAClearErrorRatherThanAnEmptyOne() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cheerio-mcp-absent-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "default.store")

        #expect(throws: MeetingStore.Failure.noStore(path: url.path(percentEncoded: false))) {
            try MeetingStore.openReadOnly(at: url)
        }
        // And crucially it does not create one on the way past: a read-only helper
        // answering "no meetings" out of a database it just made would be worse than
        // any error message.
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        let message = MeetingStore.Failure.noStore(path: url.path(percentEncoded: false)).description
        #expect(message.contains("Launch Cheerio"))
        #expect(message.contains(MeetingStore.storePathEnvironmentKey))
    }

    @Test func aStoreOnDiskOpensReadOnlyAndStaysUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cheerio-mcp-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "default.store")

        // First "process": the app, writing.
        do {
            let container = try ModelContainer(
                for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
                configurations: ModelConfiguration(url: url))
            let context = ModelContext(container)
            let meeting = Meeting(title: "Written by the app")
            meeting.segments = [TranscriptSegment(channel: .me, text: "hello", startTime: 0, endTime: 1)]
            context.insert(meeting)
            _ = meeting.stableID
            try context.save()
        }

        // Second process: the helper, read-only, over the same file.
        let service = MeetingQueryService(container: try MeetingStore.openReadOnly(at: url))
        let page = try await service.list(ListMeetingsRequest())
        #expect(page.meetings.map(\.title) == ["Written by the app"])
        let export = try await service.export(for: try #require(page.meetings.first?.uuid))
        #expect(export.segments.map(\.text) == ["hello"])

        // Nothing it did altered the data. This deliberately checks *content*, not the
        // file's mtime: SQLite's WAL bookkeeping (checkpoint on the last connection
        // closing) can legitimately touch the file's metadata on a timing-dependent
        // schedule, which made an mtime comparison flake under a parallel test run.
        // What the read-only contract actually promises is that a writable reopen
        // sees exactly what was written.
        let reopened = try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(url: url))
        let reread = try ModelContext(reopened).fetch(FetchDescriptor<Meeting>())
        #expect(reread.map(\.title) == ["Written by the app"])
        #expect(reread.first?.segments.map(\.text) == ["hello"])
    }

    /// The mechanics issue #65 is actually built on: the app's writer container and
    /// the helper's read-only container are two independent `ModelContainer`s on
    /// the same file, and the helper's is opened once and kept — see
    /// `MeetingQueryService`'s own docs on why it still creates a fresh context per
    /// call. This starts a reader that way, then makes three separate writes the
    /// same shape `CaptureSession` now makes — insert, assign `stableID`, and save
    /// together, only once both capture channels have actually started (not the
    /// moment the `Meeting` object exists, which `CaptureSession` can still unwind
    /// through its failed-start rollback with nothing yet in any context to undo),
    /// a mid-call segment checkpoint, and the final save at `stop()` — checking
    /// after each one that the long-lived reader's next call sees it, without
    /// ever reopening its container.
    @Test func writesDuringRecordingAreVisibleToAReaderOpenedBeforeTheyHappened() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cheerio-mcp-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "default.store")

        // The writer: one container, open for the whole "recording", exactly like
        // the app holds one context across `start`/checkpoints/`stop`.
        let writerContainer = try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(url: url))
        let writer = ModelContext(writerContainer)

        // The reader: opened once, before any of the writes below — this is the
        // long-lived MCP helper process, not a fresh container per assertion.
        let reader = MeetingQueryService(container: try MeetingStore.openReadOnly(at: url))

        // 1. `CaptureSession.startCapturing`, once both capture channels are
        // confirmed running: insert, assign `stableID`, save — all three together,
        // and before a single word has been transcribed.
        let meeting = Meeting(title: "Design review")
        writer.insert(meeting)
        let uuid = meeting.stableID
        try writer.save()

        let afterStart = try await reader.list(ListMeetingsRequest())
        #expect(afterStart.meetings.map(\.title) == ["Design review"])
        let listedAtStart = try #require(afterStart.meetings.first)
        #expect(listedAtStart.isInProgress)
        #expect(listedAtStart.uuid == uuid)
        #expect(listedAtStart.segmentCount == 0)

        // 2. A checkpoint mid-call: `handle(_:context:)` already inserted this
        // segment; the periodic task's job is only the `save()`.
        let segment = TranscriptSegment(channel: .me, text: "so far so good", startTime: 0, endTime: 3)
        segment.meeting = meeting
        writer.insert(segment)
        try writer.save()

        let midCall = try await reader.export(for: uuid)
        #expect(midCall.endedAt == nil)
        #expect(midCall.segments.map(\.text) == ["so far so good"])

        // 3. `stop(context:)`: another segment, `endedAt` set, saved.
        let closing = TranscriptSegment(channel: .them, text: "sounds good, ship it", startTime: 3, endTime: 6)
        closing.meeting = meeting
        writer.insert(closing)
        meeting.endedAt = .now
        try writer.save()

        let afterStop = try await reader.export(for: uuid)
        #expect(afterStop.endedAt != nil)
        #expect(afterStop.segments.map(\.text) == ["so far so good", "sounds good, ship it"])
        let finalList = try await reader.list(ListMeetingsRequest())
        #expect(finalList.meetings.first?.isInProgress == false)
    }

    // MARK: - Crash recovery

    @Test func closeAbandonedRecordingsEndsALeftoverMeetingAtItsLastTranscribedMoment() throws {
        let container = try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let iso = ISO8601DateFormatter()
        let crashed = Meeting(title: "Crashed mid-call", startedAt: iso.date(from: "2026-08-07T15:00:00Z")!)
        crashed.segments = [
            TranscriptSegment(channel: .me, text: "one", startTime: 0, endTime: 5),
            TranscriptSegment(channel: .them, text: "two", startTime: 4, endTime: 12),
        ]
        context.insert(crashed)

        // No segments at all — the crash landed before anything was transcribed.
        let stillborn = Meeting(title: "Crashed before speech", startedAt: iso.date(from: "2026-08-07T16:00:00Z")!)
        context.insert(stillborn)
        try context.save()

        #expect(StorageMigration.closeAbandonedRecordings(context: context, excluding: nil) == 2)

        // Ends at the last transcribed moment (the later segment's endTime past
        // startedAt), not "now" — a relaunch long after the crash must not silently
        // claim the gap as part of the meeting.
        #expect(crashed.endedAt == iso.date(from: "2026-08-07T15:00:12Z")!)
        #expect(stillborn.endedAt == stillborn.startedAt)

        // Idempotent: a second run has nothing left with `endedAt == nil`.
        #expect(StorageMigration.closeAbandonedRecordings(context: context, excluding: nil) == 0)
    }

    @Test func closeAbandonedRecordingsLeavesTheLiveMeetingAlone() throws {
        let container = try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        // Simulates reopening the main window mid-recording — `ContentView`'s
        // `.task` runs again while `session.meeting` is this genuinely in-progress
        // meeting, not one abandoned by a previous process.
        let recordingNow = Meeting(title: "Right now")
        context.insert(recordingNow)
        let leftoverFromACrash = Meeting(title: "Yesterday's crash")
        context.insert(leftoverFromACrash)
        try context.save()

        #expect(StorageMigration.closeAbandonedRecordings(context: context, excluding: recordingNow) == 1)
        #expect(recordingNow.endedAt == nil)
        #expect(leftoverFromACrash.endedAt != nil)
    }

    @Test func theStorePathOverrideWins() throws {
        let override = "/tmp/somewhere/else/default.store"
        #expect(
            try MeetingStore.resolveStoreURL(environment: [MeetingStore.storePathEnvironmentKey: override])
                .path(percentEncoded: false) == override)
        // Blank is not an override — an MCP client config with an empty `env` value
        // should fall back to the real store, not to the filesystem root.
        let fallback = try MeetingStore.resolveStoreURL(environment: [MeetingStore.storePathEnvironmentKey: "  "])
        #expect(fallback.lastPathComponent == AudioStorage.storeFileName)
        #expect(fallback.deletingLastPathComponent().lastPathComponent == AudioStorage.appBundleIdentifier)
    }

    // MARK: - Client setup snippets

    @Test func theSnippetsPointAtTheHelperAndStayValidInAwkwardPaths() throws {
        // App bundles live wherever the user put them, and a path with a space or a
        // quote in it must not produce config a client refuses to parse.
        let bundle = URL(filePath: "/Users/x/My Apps/Cheerio.app")
        let path = MCPClientSetup.helperURL(appBundle: bundle).path(percentEncoded: false)
        #expect(path == "/Users/x/My Apps/Cheerio.app/Contents/Helpers/cheerio-mcp")

        let json = MCPClientSetup.desktopJSON(helperPath: path)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let servers = try #require(parsed["mcpServers"] as? [String: Any])
        let cheerio = try #require(servers[MCPClientSetup.serverName] as? [String: Any])
        #expect(cheerio["command"] as? String == path)
        // Nothing else: no args, no env. A client that needs the store somewhere else
        // sets CHEERIO_STORE_PATH itself.
        #expect(Set(cheerio.keys) == ["command"])

        // A quote in the path still yields parseable JSON rather than a broken snippet —
        // and so do control characters, which macOS path components may legally carry
        // and which JSON rejects when emitted literally.
        let awkward = "/Users/x/say \"hi\"/tab\there/line\nbreak/Cheerio.app/Contents/Helpers/cheerio-mcp"
        let escaped = MCPClientSetup.desktopJSON(helperPath: awkward)
        let reparsed = try #require(try JSONSerialization.jsonObject(with: Data(escaped.utf8)) as? [String: Any])
        #expect(((reparsed["mcpServers"] as? [String: Any])?["cheerio"] as? [String: Any])?["command"] as? String == awkward)

        #expect(
            MCPClientSetup.claudeCodeCommand(helperPath: path)
                == "claude mcp add cheerio -- '/Users/x/My Apps/Cheerio.app/Contents/Helpers/cheerio-mcp'")
        #expect(MCPClientSetup.codexTOML(helperPath: path).contains("[mcp_servers.cheerio]"))
    }

    @Test func theUnreadableStoreMessageSaysWhatToDo() {
        let message = MeetingStore.Failure.unreadable(path: "/tmp/default.store", detail: "boom").description
        #expect(message.contains("schema"))
        #expect(message.contains("launch the matching version of Cheerio"))
    }
}
