import Foundation
import SwiftData
import Testing

@testable import CheerioKit

/// The hand-written JSON-RPC/MCP slice.
///
/// Taking the protocol on rather than the official SDK (see ``CheerioMCPResponder`` for
/// why) means protocol correctness is Cheerio's problem now, and these are how it stays
/// one that shows up in CI rather than in somebody's client. Every response shape a
/// client depends on is pinned here.
@Suite struct CheerioMCPResponderTests {
    private static func makeResponder() throws -> CheerioMCPResponder {
        let container = try ModelContainer(
            for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let me = EnrolledSpeaker(name: "Jackson", audioPath: "Speakers/me.caf", duration: 40)
        me.isMe = true
        context.insert(me)

        let meeting = Meeting(title: "Standup", startedAt: ISO8601DateFormatter().date(from: "2026-08-05T09:00:00Z")!)
        meeting.endedAt = meeting.startedAt.addingTimeInterval(1200)
        meeting.enhancedNotes = "## Summary\nShipping Friday."
        meeting.actionItems = [ActionItem(text: "Update the roadmap", isOwner: true, disposition: .actionable)]
        meeting.segments = [TranscriptSegment(channel: .me, text: "Morning", startTime: 0, endTime: 5)]
        context.insert(meeting)
        _ = meeting.stableID
        try context.save()

        return CheerioMCPResponder(
            service: MeetingQueryService(container: container),
            info: CheerioMCPResponder.Info(version: "0.1.0")
        )
    }

    /// One request in, the parsed reply out.
    private static func ask(_ responder: CheerioMCPResponder, _ request: String) async throws -> JSONValue {
        let reply = try #require(await responder.respond(to: Data(request.utf8)), "expected a reply to \(request)")
        // Framing: exactly one line, no embedded newline, or a client's reader
        // desynchronizes mid-session.
        #expect(!reply.contains(UInt8(ascii: "\n")))
        return try JSONDecoder().decode(JSONValue.self, from: reply)
    }

    private static func uuidOfTheOnlyMeeting(_ responder: CheerioMCPResponder) async throws -> String {
        let reply = try await ask(responder, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_meetings"}}"#)
        let text = try #require(reply["result"]?["content"]?[0]?["text"]?.stringValue)
        let page = try MeetingQueryCoding.decoder().decode(MeetingPage.self, from: Data(text.utf8))
        return try #require(page.meetings.first?.uuid).uuidString
    }

    // MARK: - initialize

    @Test func initializeAdvertisesToolsAndNothingElse() async throws {
        let responder = try Self.makeResponder()
        let reply = try await Self.ask(
            responder,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
        )

        #expect(reply["jsonrpc"]?.stringValue == "2.0")
        let result = try #require(reply["result"])
        // The client asked for a version this server supports, so it gets that one back
        // rather than being told to speak a different one.
        #expect(result["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(result["serverInfo"]?["name"]?.stringValue == "cheerio")
        #expect(result["serverInfo"]?["version"]?.stringValue == "0.1.0")
        // Tools only: advertising resources or prompts would invite calls to methods
        // this server doesn't implement.
        #expect(result["capabilities"]?.objectValue?.keys.sorted() == ["tools"])
        let instructions = try #require(result["instructions"]?.stringValue)
        #expect(instructions.contains("actionable"))
        #expect(instructions.contains("directive"))
    }

    @Test func anUnknownProtocolVersionGetsTheNewestRatherThanAnError() async throws {
        let responder = try Self.makeResponder()
        let reply = try await Self.ask(
            responder, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        #expect(reply["result"]?["protocolVersion"]?.stringValue == CheerioMCPResponder.supportedProtocolVersions[0])
        #expect(reply["error"] == nil)
    }

    @Test func initializeSurvivesMissingParams() async throws {
        // Not every client sends what the spec says it must, and refusing to start is a
        // worse outcome than agreeing on a version it can understand.
        let reply = try await Self.ask(try Self.makeResponder(), #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        #expect(reply["result"]?["protocolVersion"]?.stringValue == CheerioMCPResponder.supportedProtocolVersions[0])
    }

    // MARK: - Notifications and framing

    @Test func notificationsGetNoReply() async throws {
        let responder = try Self.makeResponder()
        // Answering a notification is a protocol violation some clients treat as fatal.
        for notification in [
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#,
            #"{"jsonrpc":"2.0","method":"something/unheard-of"}"#,
        ] {
            #expect(await responder.respond(to: Data(notification.utf8)) == nil)
        }
    }

    @Test func garbageInGetsAParseErrorNotACrash() async throws {
        let responder = try Self.makeResponder()
        let reply = try await Self.ask(responder, "this is not json")
        #expect(reply["error"]?["code"] == .int(-32700))
        #expect(reply["id"] == JSONValue.null)
    }

    @Test func aRequestWithNoMethodIsAnInvalidRequest() async throws {
        let reply = try await Self.ask(try Self.makeResponder(), #"{"jsonrpc":"2.0","id":7}"#)
        #expect(reply["error"]?["code"] == .int(-32600))
        #expect(reply["id"] == .int(7))
    }

    @Test func anUnknownMethodIsMethodNotFound() async throws {
        let reply = try await Self.ask(try Self.makeResponder(), #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
        #expect(reply["error"]?["code"] == .int(-32601))
    }

    @Test func idsComeBackExactlyAsSent() async throws {
        let responder = try Self.makeResponder()
        // JSON-RPC ids are strings or numbers and a client matches replies on them, so
        // an int must not come back as a string or vice versa.
        #expect(try await Self.ask(responder, #"{"jsonrpc":"2.0","id":42,"method":"ping"}"#)["id"] == .int(42))
        #expect(try await Self.ask(responder, #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)["id"] == .string("abc"))
    }

    @Test func pingIsAnEmptyResult() async throws {
        let reply = try await Self.ask(try Self.makeResponder(), #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(reply["result"] == .object([:]))
    }

    // MARK: - tools/list

    @Test func toolsListDescribesEveryToolAsReadOnly() async throws {
        let reply = try await Self.ask(try Self.makeResponder(), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        guard case .array(let tools) = try #require(reply["result"]?["tools"]) else {
            Issue.record("tools wasn't an array")
            return
        }

        #expect(tools.count == MeetingMCPTool.allCases.count)
        #expect(tools.compactMap { $0["name"]?.stringValue }.sorted() == MeetingMCPTool.allCases.map(\.rawValue).sorted())
        for tool in tools {
            #expect(tool["description"]?.stringValue?.isEmpty == false)
            // The schema has to arrive as a JSON object, not as the string it's authored
            // as — a client that gets a string here rejects the tool outright.
            #expect(tool["inputSchema"]?["type"]?.stringValue == "object")
            #expect(tool["inputSchema"]?["properties"]?.objectValue != nil)
            // Read-only and closed-world: lets a client skip a per-call confirmation.
            #expect(tool["annotations"]?["readOnlyHint"] == .bool(true))
            #expect(tool["annotations"]?["openWorldHint"] == .bool(false))
        }
    }

    // MARK: - tools/call

    @Test func aToolCallReturnsTheServicesJSONAsText() async throws {
        let responder = try Self.makeResponder()
        let uuid = try await Self.uuidOfTheOnlyMeeting(responder)
        let reply = try await Self.ask(
            responder,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_meeting","arguments":{"uuid":"\#(uuid)"}}}"#
        )

        let result = try #require(reply["result"])
        #expect(result["isError"] == .bool(false))
        #expect(result["content"]?[0]?["type"]?.stringValue == "text")
        let text = try #require(result["content"]?[0]?["text"]?.stringValue)
        // The payload is `MeetingExport`'s own bytes, so an agent reading over MCP and a
        // script reading the callback's file are looking at the same thing.
        let export = try MeetingQueryCoding.decoder().decode(MeetingExport.self, from: Data(text.utf8))
        #expect(export.title == "Standup")
        #expect(export.actionItems.map(\.disposition) == [.actionable])
    }

    @Test func everyToolIsReachableThroughTheProtocol() async throws {
        let responder = try Self.makeResponder()
        let uuid = try await Self.uuidOfTheOnlyMeeting(responder)
        let arguments: [MeetingMCPTool: String] = [
            .listMeetings: "{}",
            .searchMeetings: #"{"query":"shipping"}"#,
            .getMeeting: #"{"uuid":"\#(uuid)"}"#,
            .getTranscript: #"{"uuid":"\#(uuid)"}"#,
            .getActionItems: #"{"uuid":"\#(uuid)"}"#,
        ]
        for tool in MeetingMCPTool.allCases {
            let request = """
                {"jsonrpc":"2.0","id":1,"method":"tools/call",\
                "params":{"name":"\(tool.rawValue)","arguments":\(arguments[tool]!)}}
                """
            let reply = try await Self.ask(responder, request)
            #expect(reply["result"]?["isError"] == .bool(false), "\(tool.rawValue) failed")
            #expect(reply["result"]?["content"]?[0]?["text"]?.stringValue?.isEmpty == false)
        }
    }

    @Test func aCallWithNoArgumentsKeyUsesTheDefaults() async throws {
        // Clients omit `arguments` entirely when nothing is required.
        let reply = try await Self.ask(
            try Self.makeResponder(), #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_meetings"}}"#)
        #expect(reply["result"]?["isError"] == .bool(false))
    }

    @Test func toolFailuresComeBackAsResultsTheModelCanRead() async throws {
        let responder = try Self.makeResponder()
        // The distinction being pinned: a bad argument or a missing meeting is the
        // model's problem to fix, so it arrives as `isError: true` content the model
        // sees — not as a JSON-RPC error, which clients show the user as "the server
        // is broken" and never show the model at all.
        for (request, expected) in [
            (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_meeting","arguments":{}}}"#, "is required"),
            (
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_meeting","arguments":{"uuid":"\#(UUID().uuidString)"}}}"#,
                "No meeting with uuid"
            ),
            (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope"}}"#, "has no tool called"),
            (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#, "needs a tool name"),
        ] {
            let reply = try await Self.ask(responder, request)
            #expect(reply["error"] == nil, "\(request) should not be a protocol error")
            #expect(reply["result"]?["isError"] == .bool(true))
            let text = try #require(reply["result"]?["content"]?[0]?["text"]?.stringValue)
            #expect(text.contains(expected), "got: \(text)")
        }
    }

    @Test func anUnknownToolNameListsTheRealOnes() async throws {
        let reply = try await Self.ask(
            try Self.makeResponder(), #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_everything"}}"#)
        let text = try #require(reply["result"]?["content"]?[0]?["text"]?.stringValue)
        for tool in MeetingMCPTool.allCases {
            #expect(text.contains(tool.rawValue))
        }
    }

    // MARK: - No store

    @Test func withNoStoreEveryToolStillAnswersPolitely() async throws {
        let absent = FileManager.default.temporaryDirectory
            .appending(path: "cheerio-mcp-nostore-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "default.store")
        let responder = CheerioMCPResponder(storeURL: absent, info: CheerioMCPResponder.Info(version: "0.1.0"))

        // Handshake and discovery work: a client that started before Cheerio ever ran
        // should connect and show its tools, not fail to launch.
        #expect(try await Self.ask(responder, #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)["error"] == nil)
        let listed = try await Self.ask(responder, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        guard case .array(let tools) = try #require(listed["result"]?["tools"]) else {
            Issue.record("tools wasn't an array")
            return
        }
        #expect(tools.count == MeetingMCPTool.allCases.count)

        // The tool call is where it says so, and says what to do about it.
        let reply = try await Self.ask(responder, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_meetings"}}"#)
        #expect(reply["error"] == nil)
        #expect(reply["result"]?["isError"] == .bool(true))
        let text = try #require(reply["result"]?["content"]?[0]?["text"]?.stringValue)
        #expect(text.contains("Launch Cheerio"))

        // And it did not create the store it was looking for.
        #expect(!FileManager.default.fileExists(atPath: absent.path(percentEncoded: false)))
    }

    // MARK: - JSONValue

    @Test func jsonValueRoundTripsWhatTheProtocolActuallyCarries() throws {
        let source = """
            {"a":null,"b":true,"c":7,"d":1.5,"e":"x","f":[1,"two",false],"g":{"h":[]}}
            """
        let value = try #require(JSONValue(parsing: source))
        // Sorted keys and no escaped slashes: byte-stable output, which is what makes a
        // pinned protocol response testable at all.
        #expect(String(decoding: try value.encoded(), as: UTF8.self) == source)
        // Integers stay integers — a schema's `"maximum": 100` re-encoded as `100.0`
        // is rejected by some clients' validators.
        #expect(value["c"] == .int(7))
        #expect(value["d"] == .double(1.5))
        #expect(JSONValue(parsing: "{oops") == nil)
    }

    @Test func everyToolSchemaSurvivesTheTripThroughJSONValue() throws {
        // `tools/list` parses these at runtime; if one didn't survive, the tool would
        // ship with an empty schema and clients would send whatever they liked.
        for tool in MeetingMCPTool.allCases {
            let parsed = try #require(JSONValue(parsing: tool.inputSchema), "\(tool.rawValue)")
            #expect(parsed["type"] == .string("object"))
            #expect(parsed["additionalProperties"] == .bool(false))
        }
    }
}

extension JSONValue {
    /// Element at an index, for reading into `content[0]` in a test without unwrapping
    /// the array by hand each time.
    fileprivate subscript(index: Int) -> JSONValue? {
        guard case .array(let values) = self, values.indices.contains(index) else { return nil }
        return values[index]
    }
}
