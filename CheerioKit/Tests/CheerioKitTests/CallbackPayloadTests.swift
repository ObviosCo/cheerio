import Foundation
import Testing

@testable import CheerioKit

/// `CallbackPayload` is the portable half of issue #26's transcript-ready
/// callback — the part that has to work without `Process`, which isn't
/// available to whatever eventually links `CheerioKit` outside the app target.
@Suite struct CallbackPayloadTests {
    private static func makeExport(
        uuid: String,
        title: String = "Ship review",
        kind: MeetingKind = .directive
    ) -> MeetingExport {
        let meeting = Meeting(title: title)
        meeting.uuid = UUID(uuidString: uuid)
        meeting.kind = kind
        // Fixed, whole-second timestamp: ISO 8601 round-trips seconds exactly, but
        // `Date()`'s sub-second component wouldn't survive encode/decode, which
        // would make the round-trip assertion below flaky rather than deterministic.
        meeting.startedAt = ISO8601DateFormatter().date(from: "2026-08-08T09:00:00Z")!
        return meeting.export(ownerNames: [])
    }

    private static func makeTempDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "cheerio-callback-\(UUID().uuidString)")
    }

    @Test func writesTheExportJSONAndBuildsTheEnvironment() throws {
        let directory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let export = Self.makeExport(uuid: "11111111-1111-1111-1111-111111111111")
        let prepared = try CallbackPayload.prepare(export: export, in: directory)

        #expect(FileManager.default.fileExists(atPath: prepared.fileURL.path))
        #expect(prepared.fileURL.lastPathComponent == "\(export.uuid.uuidString).json")
        #expect(prepared.environment["CHEERIO_MEETING_ID"] == export.uuid.uuidString)
        #expect(prepared.environment["CHEERIO_MEETING_KIND"] == "directive")
        #expect(prepared.environment["CHEERIO_TITLE"] == "Ship review")
        #expect(prepared.environment["CHEERIO_EXPORT_PATH"] == prepared.fileURL.path)

        // The file on disk is exactly what a caller would pipe to stdin — no
        // second, differently-formatted encode happening anywhere.
        let onDisk = try Data(contentsOf: prepared.fileURL)
        #expect(onDisk == prepared.jsonData)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingExport.self, from: onDisk)
        #expect(decoded == export)
    }

    @Test func perMeetingNamingKeepsTwoMeetingsPayloadsSeparate() throws {
        let directory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = Self.makeExport(uuid: "11111111-1111-1111-1111-111111111111", title: "Standup")
        let second = Self.makeExport(uuid: "22222222-2222-2222-2222-222222222222", title: "1:1")

        let firstPrepared = try CallbackPayload.prepare(export: first, in: directory)
        let secondPrepared = try CallbackPayload.prepare(export: second, in: directory)

        #expect(firstPrepared.fileURL != secondPrepared.fileURL)
        #expect(FileManager.default.fileExists(atPath: firstPrepared.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: secondPrepared.fileURL.path))
    }

    @Test func rerunningTheSameMeetingOverwritesRatherThanFailing() throws {
        // The "run now on last meeting" test button can fire more than once for
        // the same meeting — that must never throw over a file that already exists.
        let directory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let export = Self.makeExport(uuid: "33333333-3333-3333-3333-333333333333")
        _ = try CallbackPayload.prepare(export: export, in: directory)
        let second = try CallbackPayload.prepare(export: export, in: directory)

        #expect(FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    @Test func defaultDirectoryLivesUnderApplicationSupport() throws {
        let directory = try CallbackPayload.defaultDirectory()
        let applicationSupport = try AudioStorage.applicationSupport()
        #expect(directory.path.hasPrefix(applicationSupport.path))
        #expect(directory.lastPathComponent == "Callbacks")
    }
}
