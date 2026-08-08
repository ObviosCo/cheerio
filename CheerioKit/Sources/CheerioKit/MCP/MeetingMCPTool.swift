import Foundation

/// The tools the bundled MCP helper exposes — the whole surface, in one enum, so the
/// helper's `tools/list` and its `tools/call` switch cannot fall out of step with each
/// other or with what the tests exercise.
///
/// All five are read-only. There is no tool here that writes, deletes, starts a
/// recording, or runs a command: an agent reaching Cheerio over MCP is a reader of
/// meeting history and nothing else. The push direction — Cheerio handing a finished
/// transcript to an agent — is the transcript-ready callback (issue #26), which is a
/// separate mechanism the user configures deliberately.
///
/// Descriptions and JSON schemas live here rather than in the executable because they
/// are the part of the protocol surface most likely to need editing on the evidence of
/// how models actually call these, and a test can hold them to being well-formed.
public enum MeetingMCPTool: String, CaseIterable, Sendable {
    case listMeetings = "list_meetings"
    case getMeeting = "get_meeting"
    case getTranscript = "get_transcript"
    case searchMeetings = "search_meetings"
    case getActionItems = "get_action_items"

    public var description: String {
        switch self {
        case .listMeetings:
            """
            List recorded meetings and directive sessions, most recent first. Returns metadata only — \
            call get_meeting or get_transcript for the contents. A recording still in progress is \
            included with isInProgress true; its transcript reflects the store's most recent save, \
            which may trail the live meeting or be empty until it finishes.
            """
        case .getMeeting:
            """
            Get one meeting in full by its uuid: metadata, the user's rough notes, the AI-enhanced \
            notes, the structured action items, and every transcript line. Use list_meetings or \
            search_meetings first to find the uuid.
            """
        case .getTranscript:
            """
            Get one meeting's transcript by uuid: speaker-labelled lines in chronological order, each \
            flagged with whether it was the user speaking (isOwner) and which capture channel it came \
            from. Cheaper than get_meeting when you only need what was said.
            """
        case .searchMeetings:
            """
            Find meetings by free text, matched case-insensitively against the title, the user's rough \
            notes, the enhanced notes, speaker names, and every transcript line. Returns the same \
            metadata as list_meetings.
            """
        case .getActionItems:
            """
            Get one meeting's action items by uuid, as structure rather than prose. Each carries an \
            owner, an isOwner flag, and a disposition: 'actionable' means the user committed to it \
            themselves and an agent may carry it out; 'followUp' means someone else committed or \
            nobody did — track it, never do it on their behalf.
            """
        }
    }

    /// The tool's JSON Schema, as source text.
    ///
    /// A string literal rather than a Swift model of JSON Schema: this is data the
    /// helper hands the protocol verbatim, a reviewer can read it against the request
    /// structs in one glance, and ``MeetingMCPToolTests`` parses every one of them, so
    /// a typo is a test failure rather than a client-side surprise.
    public var inputSchema: String {
        switch self {
        case .listMeetings:
            """
            {
              "type": "object",
              "properties": {
                \(Self.filterProperties),
                \(Self.pagingProperties)
              },
              "additionalProperties": false
            }
            """
        case .searchMeetings:
            """
            {
              "type": "object",
              "properties": {
                "query": {
                  "type": "string",
                  "description": "Text to look for, matched case-insensitively against titles, notes, speaker names and transcript lines"
                },
                \(Self.filterProperties),
                \(Self.pagingProperties)
              },
              "required": ["query"],
              "additionalProperties": false
            }
            """
        case .getMeeting, .getTranscript, .getActionItems:
            """
            {
              "type": "object",
              "properties": {
                "uuid": {
                  "type": "string",
                  "format": "uuid",
                  "description": "The meeting's uuid, as returned by list_meetings or search_meetings"
                }
              },
              "required": ["uuid"],
              "additionalProperties": false
            }
            """
        }
    }

    private static let filterProperties = """
        "kind": {
              "type": "string",
              "enum": ["meeting", "directive"],
              "description": "Only meetings of this kind. 'directive' is the user talking instructions at their agent rather than a conversation"
            },
            "since": {
              "type": "string",
              "description": "Only meetings that started at or after this time. ISO 8601, or a plain date like 2026-08-01"
            },
            "until": {
              "type": "string",
              "description": "Only meetings that started before this time. ISO 8601, or a plain date like 2026-08-01"
            }
        """

    private static let pagingProperties = """
        "limit": {
              "type": "integer",
              "minimum": 1,
              "maximum": \(MeetingQueryService.maximumLimit),
              "description": "How many to return. Defaults to \(MeetingQueryService.defaultLimit)"
            },
            "offset": {
              "type": "integer",
              "minimum": 0,
              "description": "How many matches to skip, for paging. Check hasMore and total in the result"
            }
        """
}
