import Foundation
import Testing

@testable import CheerioKit

/// `MeetingExport`'s JSON shape is API the moment the transcript-ready callback
/// ships, so this pins the exact bytes rather than just round-tripping through
/// `Codable` — a downstream consumer can diff against this fixture directly.
@Suite struct MeetingExportTests {
    private static let fixedUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private static func makeMeeting() -> Meeting {
        let meeting = Meeting(title: "Standup")
        meeting.uuid = fixedUUID
        let iso = ISO8601DateFormatter()
        meeting.startedAt = iso.date(from: "2026-08-08T09:00:00Z")!
        meeting.endedAt = iso.date(from: "2026-08-08T09:30:00Z")!
        meeting.roughNotes = "checked on the roadmap"
        meeting.enhancedNotes = "## Summary\nAll good."
        meeting.participantNames = ["Jackson", "Carter"]
        meeting.actionItems = [
            // One of each disposition: what a consumer routes on. The owner's item
            // names nobody, so its missing `owner` key is part of the pinned shape.
            ActionItem(text: "Update the roadmap", isOwner: true, disposition: .actionable),
            ActionItem(text: "Send the contract", owner: "Carter", isOwner: false, disposition: .followUp),
        ]

        // Undiarized mic line: owner-attributed by channel alone.
        let mine = TranscriptSegment(channel: .me, text: "Morning", startTime: 0, endTime: 5)
        // Enrolled label naming a guest: never owner-attributed, even though it's a
        // named identity rather than a diarizer placeholder.
        let guest = TranscriptSegment(channel: .them, text: "Let's ship Friday", startTime: 5, endTime: 10)
        guest.speakerLabel = "Carter"

        meeting.segments = [mine, guest]
        return meeting
    }

    @Test func exportCapturesTheMeetingAndOwnerAttribution() {
        let meeting = Self.makeMeeting()
        let export = meeting.export(ownerNames: ["Jackson"])

        #expect(export.uuid == Self.fixedUUID)
        #expect(export.kind == .meeting)
        #expect(export.segments.map(\.isOwner) == [true, false])
        #expect(export.segments.map(\.displayLabel) == ["Me", "Carter"])
        #expect(export.actionItems.map(\.disposition) == [.actionable, .followUp])
    }

    @Test func jsonShapeIsExact() throws {
        let meeting = Self.makeMeeting()
        let export = meeting.export(ownerNames: ["Jackson"])

        // No formatting overrides: the fixture pins the bytes consumers actually ship.
        let data = try MeetingExport.makeJSONEncoder().encode(export)
        let json = String(decoding: data, as: UTF8.self)

        let expected = """
            {"actionItems":[\
            {"disposition":"actionable","isOwner":true,"text":"Update the roadmap"},\
            {"disposition":"followUp","isOwner":false,"owner":"Carter","text":"Send the contract"}\
            ],\
            "endedAt":"2026-08-08T09:30:00Z","enhancedNotes":"## Summary\\nAll good.",\
            "kind":"meeting","participantNames":["Jackson","Carter"],\
            "roughNotes":"checked on the roadmap",\
            "segments":[\
            {"channel":"me","displayLabel":"Me","endTime":5,"isOwner":true,"startTime":0,"text":"Morning"},\
            {"channel":"them","displayLabel":"Carter","endTime":10,"isOwner":false,"startTime":5,"text":"Let's ship Friday"}\
            ],\
            "startedAt":"2026-08-08T09:00:00Z","title":"Standup",\
            "uuid":"00000000-0000-0000-0000-000000000001"}
            """

        #expect(json == expected)
    }

    @Test func jsonShapeOmitsNilOptionalsRatherThanEmittingNull() throws {
        // The other fixture populates every optional, so it can't catch the
        // key-presence decision changing. This one pins it: a meeting that's still
        // running (no end), never enhanced, and with no roster *omits* those keys —
        // synthesized Codable's behavior, but now a choice consumers can rely on
        // instead of an accident.
        let meeting = Meeting(title: "Standup")
        meeting.uuid = Self.fixedUUID
        meeting.startedAt = ISO8601DateFormatter().date(from: "2026-08-08T09:00:00Z")!

        let data = try MeetingExport.makeJSONEncoder().encode(meeting.export(ownerNames: []))
        let json = String(decoding: data, as: UTF8.self)

        let expected = """
            {"actionItems":[],"kind":"meeting","roughNotes":"","segments":[],\
            "startedAt":"2026-08-08T09:00:00Z","title":"Standup",\
            "uuid":"00000000-0000-0000-0000-000000000001"}
            """

        #expect(json == expected)
    }

    @Test func directiveKindSurvivesExport() {
        let meeting = Self.makeMeeting()
        meeting.kind = .directive
        let export = meeting.export(ownerNames: ["Jackson"])
        #expect(export.kind == .directive)
    }
}
