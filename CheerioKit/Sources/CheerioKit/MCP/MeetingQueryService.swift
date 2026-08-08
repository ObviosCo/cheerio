import Foundation
import SwiftData

/// Answers the MCP tools, against a store it only ever reads.
///
/// This is where all of the helper's behaviour lives. The executable that ships in
/// `Cheerio.app` is stdin/stdout plumbing over ``handle(tool:arguments:)`` — decode a
/// `tools/call`, hand the arguments here as JSON, put the JSON that comes back in a
/// text content block — so everything worth testing is testable in the package,
/// against an in-memory store, with no transport in the picture.
///
/// An actor because ``ModelContext`` is not `Sendable` and the request handlers are
/// `@Sendable` closures. Contexts are created *inside* the actor from the
/// ``ModelContainer`` (which is `Sendable`), so none ever crosses an isolation
/// boundary. Serializing the reads costs nothing here: stdio delivers one request at a
/// time.
public actor MeetingQueryService {
    public static let defaultLimit = 20
    /// Ceiling on a page, applied whatever the caller asked for. Twenty full
    /// transcripts is more than a client's context wants and a hundred summaries is
    /// already a lot of meetings; the number is a guard against a caller passing
    /// `limit: 100000` and getting the entire store back as one string.
    public static let maximumLimit = 100

    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    /// A fresh context per call, deliberately.
    ///
    /// The helper is long-lived — an MCP client starts it once and keeps it — while the
    /// app carries on recording, enhancing, and relabelling in the store underneath.
    /// A context held across calls would answer the second question out of the row
    /// cache it filled answering the first, so a meeting that ended and got notes in
    /// between would still read as in progress. A new context is cheap and has nothing
    /// stale to serve.
    ///
    /// `autosaveEnabled` off is belt to `allowsSave: false`'s braces: nothing here
    /// mutates a model, but if something ever did it would fail at an explicit
    /// `save()` rather than getting one for free at the end of the run loop.
    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    /// What a tool call can fail with, in terms an agent can relay to a person.
    public enum Failure: Error, CustomStringConvertible, Sendable, Equatable {
        case invalidArguments(tool: MeetingMCPTool, detail: String)
        case noSuchMeeting(uuid: UUID)
        case fetchFailed(detail: String)

        public var description: String {
            switch self {
            case .invalidArguments(let tool, let detail):
                "Couldn't read the arguments to \(tool.rawValue): \(detail)"
            case .noSuchMeeting(let uuid):
                """
                No meeting with uuid \(uuid.uuidString). It may have been deleted, or — if it predates \
                this version of Cheerio — it may not have an identifier yet; open Cheerio once and it \
                will assign one. Use list_meetings to see what's there.
                """
            case .fetchFailed(let detail):
                "Couldn't read the Cheerio store: \(detail)"
            }
        }
    }

    /// Runs one tool call: JSON arguments in, JSON result out.
    ///
    /// - Parameter arguments: the `arguments` object from a `tools/call`. Empty data
    ///   is read as `{}`, so a client that omits arguments entirely gets the defaults
    ///   rather than a decoding error.
    public func handle(tool: MeetingMCPTool, arguments: Data) throws -> Data {
        let decoder = MeetingQueryCoding.decoder()
        let arguments = arguments.isEmpty ? Data("{}".utf8) : arguments

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            do {
                return try decoder.decode(type, from: arguments)
            } catch {
                throw Failure.invalidArguments(tool: tool, detail: readableDecodingError(error))
            }
        }

        let context = makeContext()
        let encoder = MeetingQueryCoding.encoder()
        switch tool {
        case .listMeetings:
            return try encoder.encode(list(decode(ListMeetingsRequest.self), in: context))
        case .searchMeetings:
            return try encoder.encode(search(decode(SearchMeetingsRequest.self), in: context))
        case .getMeeting:
            return try encoder.encode(export(for: decode(MeetingIDRequest.self).uuid, in: context))
        case .getTranscript:
            let export = try export(for: decode(MeetingIDRequest.self).uuid, in: context)
            return try encoder.encode(TranscriptResult(export: export))
        case .getActionItems:
            let export = try export(for: decode(MeetingIDRequest.self).uuid, in: context)
            return try encoder.encode(ActionItemsResult(export: export))
        }
    }

    // MARK: - Tools

    /// `list_meetings`. The `in:` overloads exist for tests and for ``handle`` to share
    /// one context across a call; the context-free versions are the ordinary entry
    /// points.
    public func list(_ request: ListMeetingsRequest) throws -> MeetingPage {
        try list(request, in: makeContext())
    }

    public func search(_ request: SearchMeetingsRequest) throws -> MeetingPage {
        try search(request, in: makeContext())
    }

    /// The full ``MeetingExport`` for one meeting — what `get_meeting` returns, and
    /// what `get_transcript` and `get_action_items` narrow down.
    ///
    /// One source for all three so they can't describe the same meeting differently,
    /// and `readOnlyExport` specifically so that reading a legacy row doesn't try to
    /// write an identifier into a store opened without permission to.
    public func export(for uuid: UUID) throws -> MeetingExport {
        try export(for: uuid, in: makeContext())
    }

    private func list(_ request: ListMeetingsRequest, in context: ModelContext) throws -> MeetingPage {
        try page(from: matching(request, in: context), request: request, in: context)
    }

    private func search(_ request: SearchMeetingsRequest, in context: ModelContext) throws -> MeetingPage {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw Failure.invalidArguments(tool: .searchMeetings, detail: "query was empty")
        }
        // `Meeting.matches` is the app's own search, reused rather than reimplemented
        // as a predicate, so a phrase an agent searches for finds the same meetings the
        // user's sidebar search finds. It reads segment text, which SwiftData can't
        // express as a store-level predicate anyway.
        let matches = try matching(request.listRequest, in: context).filter { $0.matches(query) }
        return try page(from: matches, request: request.listRequest, in: context)
    }

    private func export(for uuid: UUID, in context: ModelContext) throws -> MeetingExport {
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.uuid == uuid })
        let meeting: Meeting?
        do {
            meeting = try context.fetch(descriptor).first
        } catch {
            throw Failure.fetchFailed(detail: "\(error)")
        }
        guard let meeting, let export = meeting.readOnlyExport(ownerNames: try ownerNames(in: context)) else {
            throw Failure.noSuchMeeting(uuid: uuid)
        }
        return export
    }

    // MARK: - Fetching

    /// Every meeting passing `request`'s filters, newest first.
    ///
    /// Sorting happens in the store; `kind` and the date range are applied in Swift
    /// afterwards. That split is deliberate: a `#Predicate` over three independently
    /// optional filters is a pile of conditional predicate building for a store that
    /// holds one person's meetings, and `search_meetings` has to walk the results in
    /// Swift regardless. If this ever gets slow, the fix is a predicate for the date
    /// range, which is the one bound that can actually exclude most of a long history.
    private func matching(_ request: ListMeetingsRequest, in context: ModelContext) throws -> [Meeting] {
        let descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        do {
            return try context.fetch(descriptor).filter { meeting in
                if let kind = request.kind, meeting.kind != kind { return false }
                if let since = request.since, meeting.startedAt < since { return false }
                if let until = request.until, meeting.startedAt >= until { return false }
                return true
            }
        } catch {
            throw Failure.fetchFailed(detail: "\(error)")
        }
    }

    private func page(from meetings: [Meeting], request: ListMeetingsRequest, in context: ModelContext) throws -> MeetingPage {
        let limit = min(max(request.limit ?? Self.defaultLimit, 1), Self.maximumLimit)
        let offset = max(request.offset ?? 0, 0)
        let names = try ownerNames(in: context)
        let window = meetings.dropFirst(offset).prefix(limit)
        return MeetingPage(
            meetings: window.map { MeetingSummary(meeting: $0, ownerNames: names) },
            total: meetings.count,
            offset: offset,
            limit: limit
        )
    }

    /// The enrolled names flagged `isMe` — the owner-attribution input every result
    /// here threads through, same as the app does.
    ///
    /// Read on each call rather than cached: the app is running alongside this process
    /// and the user can flip `isMe` in Settings mid-session, and a stale answer here
    /// would mislabel who committed to what.
    private func ownerNames(in context: ModelContext) throws -> Set<String> {
        do {
            let enrolled = try context.fetch(FetchDescriptor<EnrolledSpeaker>(predicate: #Predicate { $0.isMe }))
            return Set(enrolled.map(\.name))
        } catch {
            throw Failure.fetchFailed(detail: "\(error)")
        }
    }

    /// Turns a `DecodingError` into something worth showing a caller.
    ///
    /// `\(error)` on a `DecodingError` is a paragraph of Swift internals; the useful
    /// part is which key was wrong and why, because the caller is a model that can fix
    /// its own arguments if it's told what to fix.
    private func readableDecodingError(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "\(error)" }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }
            return keys.isEmpty ? "the arguments" : "“\(keys.joined(separator: "."))”"
        }
        switch error {
        case .keyNotFound(let key, _):
            return "“\(key.stringValue)” is required"
        case .typeMismatch(let type, let context), .valueNotFound(let type, let context):
            return "\(path(context)) should be \(type): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "\(path(context)) isn't valid: \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}
