import Foundation

// The request and result types the MCP tools speak, and the JSON coders that
// serialize them. Everything here is plain `Codable` value types on purpose: this is
// the file a reviewer reads to know exactly what an agent can ask for and what comes
// back, without any MCP protocol types in the way.

/// One meeting as it appears in a list, which is ``MeetingExport`` minus the two
/// fields that dominate its size.
///
/// A strict subset by design — every field here is spelled and typed exactly as
/// `MeetingExport` spells it, so `list_meetings` and `get_meeting` never disagree
/// about the same meeting. What's left out is `roughNotes`/`enhancedNotes` and
/// `segments`, replaced by counts: a page of twenty meetings would otherwise carry
/// twenty full transcripts, which is both the whole store and more context than any
/// caller wanted from a list.
public struct MeetingSummary: Codable, Sendable, Equatable {
    /// Nil for a meeting the app hasn't assigned one to yet — see
    /// ``unavailable``, and ``Meeting/readOnlyExport(ownerNames:)`` for why the
    /// helper won't invent one.
    public let uuid: UUID?
    public let title: String
    public let kind: MeetingKind
    public let startedAt: Date
    public let endedAt: Date?
    public let participantNames: [String]?
    /// True while this meeting is still being recorded. Its transcript is readable
    /// but incomplete, and it has no notes or action items yet.
    public let isInProgress: Bool
    public let segmentCount: Int
    public let hasEnhancedNotes: Bool
    public let actionItemCount: Int
    /// Why this meeting can't be fetched by id, when it can't. Nil in the normal
    /// case. Present rather than the row being hidden, because an agent that has been
    /// told a meeting exists and why it's unreachable can tell the user something
    /// useful; one shown a short list can only conclude the history is short.
    public let unavailable: String?

    /// - Parameter ownerNames: enrolled `isMe` names, only used for the action-item
    ///   count, which is reconciled for the same reason ``MeetingExport`` reconciles.
    public init(meeting: Meeting, ownerNames: Set<String>) {
        self.uuid = meeting.uuid
        self.title = meeting.title
        self.kind = meeting.kind
        self.startedAt = meeting.startedAt
        self.endedAt = meeting.endedAt
        self.participantNames = meeting.participantNames
        self.isInProgress = meeting.endedAt == nil
        // Counted the way `get_transcript` counts: bleed lines never reach the
        // export's segments, so a summary advertising them would promise lines the
        // fetch doesn't deliver.
        self.segmentCount = meeting.segments.count(where: { !$0.isBleed })
        self.hasEnhancedNotes = meeting.enhancedNotes?.isEmpty == false
        self.actionItemCount = meeting.reconciledActionItems(ownerNames: ownerNames).count
        self.unavailable =
            meeting.uuid == nil
            ? """
            This meeting has no identifier yet, so it can't be fetched individually. \
            Open Cheerio once and it will assign one.
            """
            : nil
    }
}

/// A page of ``MeetingSummary``, with enough around it to page without guessing.
public struct MeetingPage: Codable, Sendable, Equatable {
    public let meetings: [MeetingSummary]
    /// How many matched in total, before `offset`/`limit` — so a caller knows whether
    /// "three results" means three or means the first three.
    public let total: Int
    public let offset: Int
    public let limit: Int
    /// Whether another page follows. Stored rather than computed on purpose: a computed
    /// property is invisible to `Codable`, so as a `var` this was absent from the JSON
    /// while `list_meetings`' own description told callers to check it.
    public let hasMore: Bool

    public init(meetings: [MeetingSummary], total: Int, offset: Int, limit: Int) {
        self.meetings = meetings
        self.total = total
        self.offset = offset
        self.limit = limit
        self.hasMore = offset + meetings.count < total
    }
}

/// The `get_transcript` result: speaker-labelled lines with owner flags, which is
/// ``MeetingExport``'s `segments` and the little you need to know you're reading the
/// right meeting.
public struct TranscriptResult: Codable, Sendable, Equatable {
    public let uuid: UUID
    public let title: String
    public let startedAt: Date
    /// True when this is the recording in progress: the lines are what has been
    /// transcribed so far, not the whole meeting.
    public let isInProgress: Bool
    public let segments: [MeetingExport.Segment]

    public init(export: MeetingExport) {
        self.uuid = export.uuid
        self.title = export.title
        self.startedAt = export.startedAt
        self.isInProgress = export.endedAt == nil
        self.segments = export.segments
    }
}

/// The `get_action_items` result. Always built from ``MeetingExport``, whose items are
/// reconciled against current speaker identity, so a label corrected after the notes
/// were generated can't leave an agent acting on stale attribution.
public struct ActionItemsResult: Codable, Sendable, Equatable {
    public let uuid: UUID
    public let title: String
    public let actionItems: [ActionItem]

    public init(export: MeetingExport) {
        self.uuid = export.uuid
        self.title = export.title
        self.actionItems = export.actionItems
    }
}

// MARK: - Requests

/// Arguments to `list_meetings`.
///
/// Every field optional, and decoded from the client's JSON, so a tool call with no
/// arguments at all is valid and means "the most recent page".
public struct ListMeetingsRequest: Codable, Sendable, Equatable {
    public var kind: MeetingKind?
    /// Inclusive lower bound on `startedAt`.
    public var since: Date?
    /// Exclusive upper bound on `startedAt`.
    public var until: Date?
    public var limit: Int?
    public var offset: Int?

    public init(kind: MeetingKind? = nil, since: Date? = nil, until: Date? = nil, limit: Int? = nil, offset: Int? = nil) {
        self.kind = kind
        self.since = since
        self.until = until
        self.limit = limit
        self.offset = offset
    }
}

/// Arguments to `search_meetings`. Same paging and filters as `list_meetings`, plus
/// the query — searching is a filtered list, and giving it a different shape would
/// only make an agent learn two.
public struct SearchMeetingsRequest: Codable, Sendable, Equatable {
    public var query: String
    public var kind: MeetingKind?
    public var since: Date?
    public var until: Date?
    public var limit: Int?
    public var offset: Int?

    public init(
        query: String, kind: MeetingKind? = nil, since: Date? = nil, until: Date? = nil,
        limit: Int? = nil, offset: Int? = nil
    ) {
        self.query = query
        self.kind = kind
        self.since = since
        self.until = until
        self.limit = limit
        self.offset = offset
    }

    var listRequest: ListMeetingsRequest {
        ListMeetingsRequest(kind: kind, since: since, until: until, limit: limit, offset: offset)
    }
}

/// Arguments to the three by-id tools.
public struct MeetingIDRequest: Codable, Sendable, Equatable {
    public var uuid: UUID

    public init(uuid: UUID) {
        self.uuid = uuid
    }
}

// MARK: - Coding

/// The JSON coders the MCP tools use.
///
/// Encoding is ``MeetingExport/makeJSONEncoder()`` exactly — same ISO 8601 dates,
/// same sorted keys — because a meeting an agent reads over MCP and the same meeting
/// arriving through the transcript-ready callback have to be the same bytes.
enum MeetingQueryCoding {
    static func encoder() -> JSONEncoder { MeetingExport.makeJSONEncoder() }

    /// Decoder for tool arguments.
    ///
    /// Date decoding is deliberately looser than the encoder's ISO 8601 output. Dates
    /// out of this helper are always full timestamps, but dates *into* it are typed by
    /// a language model, which reaches for `2026-08-01` about as often as for
    /// `2026-08-01T00:00:00Z`. Rejecting the short form would be a tool that fails for
    /// a reason the caller can't see in its own arguments.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription:
                            "Expected an ISO 8601 date like 2026-08-01T09:30:00Z or a plain 2026-08-01, got “\(text)”"
                    ))
            }
            return date
        }
        return decoder
    }

    /// Accepts a full ISO 8601 timestamp, with or without fractional seconds, or a
    /// bare calendar date — which is read in the current time zone, since a caller who
    /// typed "since August 1st" meant their August 1st.
    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for strategy in [Date.ISO8601FormatStyle(), Date.ISO8601FormatStyle(includingFractionalSeconds: true)] {
            if let date = try? strategy.parse(trimmed) { return date }
        }
        if let day = try? Date.ISO8601FormatStyle(timeZone: .current).year().month().day().parse(trimmed) {
            return day
        }
        return nil
    }
}
