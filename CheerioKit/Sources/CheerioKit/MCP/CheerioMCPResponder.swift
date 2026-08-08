import Foundation

/// One JSON-RPC message in, at most one out — the whole of Cheerio's MCP server bar
/// the file descriptors.
///
/// ## Why this is hand-written
///
/// The official `modelcontextprotocol/swift-sdk` was the obvious choice and was
/// rejected on evidence, not taste. Its `MCP` library target contains
/// `import Network` and seven `URLSession` call sites (`HTTPClientTransport` plus the
/// whole OAuth stack), and it resolves `swift-nio`, `swift-atomics` and
/// `swift-collections` transitively. Cheerio's local-only property does not rest on an
/// entitlement — the sandbox is off, so entitlements enforce nothing — it rests on
/// there being no networking code in the shipped bundle at all, which is a thing a
/// reviewer can check by grepping. Linking Network.framework into a helper inside
/// `Cheerio.app` would replace that check with "trust us, we only construct the stdio
/// transport". The SDK is also pre-1.0 with a `branch: "main"` dependency of its own,
/// against a repo that pins its one existing dependency exactly.
///
/// What a stdio, tools-only, read-only server actually needs is `initialize`,
/// `tools/list`, `tools/call`, `ping`, newline-delimited framing and a JSON-RPC error
/// envelope. That is this file. The trade accepted in exchange: protocol drift is now
/// Cheerio's problem, so the supported revisions are listed explicitly in
/// ``supportedProtocolVersions`` and the shape of every response is pinned by tests.
///
/// It lives in `CheerioKit` rather than in the executable for one reason: hand-rolled
/// protocol code that no test can reach is the actual risk of hand-rolling, and an
/// Xcode command-line-tool target has no test target. The app links this — inert value
/// types and a switch, no I/O, nothing that runs unless something feeds it a request.
public actor CheerioMCPResponder {
    /// What `initialize` reports about this server.
    public struct Info: Sendable {
        public var name: String
        public var version: String
        /// Shown to the model alongside the tool list. Worth spending words on: it is
        /// the only place to say what Cheerio *is*, and that `disposition` is a
        /// permission rather than a priority.
        public var instructions: String

        public init(name: String = "cheerio", version: String, instructions: String = Info.defaultInstructions) {
            self.name = name
            self.version = version
            self.instructions = instructions
        }

        public static let defaultInstructions = """
            Cheerio records and transcribes meetings on this Mac, locally. These tools read that \
            history; none of them can change it, start a recording, or run anything.

            Meetings have two kinds: 'meeting' is a conversation, 'directive' is the user talking \
            instructions at their agent rather than to other people — treat a directive's transcript \
            as addressed to you.

            Action items carry a disposition. 'actionable' means the user committed to it themselves \
            and you may carry it out. 'followUp' means someone else committed, or nobody did: track it \
            and prepare for it, but never do it on their behalf. That distinction comes from who was \
            speaking, so it is a permission, not a priority.
            """
    }

    /// MCP revisions this server will agree to.
    ///
    /// A tools-only server behaves identically across all of these — nothing here uses
    /// a feature that changed between them — so the list is "what a client might ask
    /// for", newest first. An unrecognized version gets the newest rather than an
    /// error, which is what the spec asks for and what keeps a client from next year
    /// failing to connect to a Cheerio from this one.
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let info: Info
    private let storeURL: URL?
    private var service: MeetingQueryService?

    /// - Parameter storeURL: opened on the first tool call, not here.
    ///
    ///   Deferring it is deliberate. An MCP client launches this helper and keeps it
    ///   for the session, quite possibly before Cheerio has ever run; opening at start
    ///   would leave a server that is permanently broken for a reason that fixed itself
    ///   minutes later. Failing per-call means the first attempt explains what to do
    ///   and the next one just works.
    public init(storeURL: URL, info: Info) {
        self.storeURL = storeURL
        self.info = info
    }

    /// For tests and for anything that already has a store open.
    public init(service: MeetingQueryService, info: Info) {
        self.storeURL = nil
        self.service = service
        self.info = info
    }

    /// Handles one line of JSON-RPC. Returns the line to write back, or nil when the
    /// message was a notification — those get no response, ever, and answering one is
    /// a protocol violation that some clients treat as fatal.
    public func respond(to line: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line), message.objectValue != nil else {
            return encode(.object(["jsonrpc": .string("2.0"), "id": .null, "error": Self.error(-32700, "Parse error")]))
        }
        guard let method = message["method"]?.stringValue else {
            guard let id = message["id"] else { return nil }
            return encode(response(id: id, error: Self.error(-32600, "Not a JSON-RPC request: no method")))
        }
        // No `id` means a notification. `notifications/initialized` is the one this
        // server expects; the rest are equally fine to drop, since it advertises no
        // capability whose notifications matter.
        guard let id = message["id"] else { return nil }

        switch method {
        case "initialize":
            return encode(response(id: id, result: initializeResult(params: message["params"])))
        case "ping":
            return encode(response(id: id, result: .object([:])))
        case "tools/list":
            return encode(response(id: id, result: toolsListResult()))
        case "tools/call":
            return encode(response(id: id, result: await callToolResult(params: message["params"])))
        default:
            return encode(response(id: id, error: Self.error(-32601, "Method not found: \(method)")))
        }
    }

    // MARK: - Methods

    private func initializeResult(params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.stringValue
        let version =
            Self.supportedProtocolVersions.contains(requested ?? "")
            ? requested! : Self.supportedProtocolVersions[0]
        return .object([
            "protocolVersion": .string(version),
            // Tools and nothing else. No resources, no prompts, no sampling, no
            // logging — advertising a capability this server doesn't implement is how
            // a client ends up calling a method that isn't there.
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object(["name": .string(info.name), "version": .string(info.version)]),
            "instructions": .string(info.instructions),
        ])
    }

    private func toolsListResult() -> JSONValue {
        let tools = MeetingMCPTool.allCases.map { tool in
            JSONValue.object([
                "name": .string(tool.rawValue),
                "description": .string(tool.description),
                // Parsed rather than passed through as a string, because `inputSchema`
                // is a JSON object on the wire. A schema that failed to parse would be
                // a build-time typo, and `MeetingMCPTests` parses all five; `.object`
                // empty is the honest fallback rather than a crash in a helper whose
                // job is to be unfailingly polite.
                "inputSchema": JSONValue(parsing: tool.inputSchema) ?? .object(["type": .string("object")]),
                // Every tool here reads. Saying so lets a client skip a confirmation
                // prompt it would otherwise have to show for each call.
                "annotations": .object(["readOnlyHint": .bool(true), "openWorldHint": .bool(false)]),
            ])
        }
        return .object(["tools": .array(tools)])
    }

    private func callToolResult(params: JSONValue?) async -> JSONValue {
        guard let name = params?["name"]?.stringValue else {
            return Self.toolFailure("A tools/call needs a tool name.")
        }
        guard let tool = MeetingMCPTool(rawValue: name) else {
            let known = MeetingMCPTool.allCases.map(\.rawValue).joined(separator: ", ")
            return Self.toolFailure("Cheerio has no tool called “\(name)”. It has: \(known).")
        }

        let arguments: Data
        if let object = params?["arguments"], object != .null {
            guard let encoded = try? object.encoded() else {
                return Self.toolFailure("Couldn't read the arguments to \(name).")
            }
            arguments = encoded
        } else {
            arguments = Data()
        }

        do {
            let json = try await requireService().handle(tool: tool, arguments: arguments)
            return Self.toolSuccess(String(decoding: json, as: UTF8.self))
        } catch let failure as MeetingQueryService.Failure {
            return Self.toolFailure(failure.description)
        } catch let failure as MeetingStore.Failure {
            return Self.toolFailure(failure.description)
        } catch {
            return Self.toolFailure("Cheerio couldn't answer that: \(error)")
        }
    }

    /// The store, opened on demand and kept once it opens.
    private func requireService() throws -> MeetingQueryService {
        if let service { return service }
        guard let storeURL else { throw MeetingStore.Failure.noStore(path: "(none configured)") }
        let opened = MeetingQueryService(container: try MeetingStore.openReadOnly(at: storeURL))
        service = opened
        return opened
    }

    // MARK: - Envelopes

    /// A tool result the model reads as data.
    ///
    /// Text, not `structuredContent`: the latter arrived in a later revision than some
    /// clients implement, and a JSON string is what every one of them can already show
    /// a model. The bytes inside are ``MeetingExport``'s own encoding either way.
    static func toolSuccess(_ text: String) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(false),
        ])
    }

    /// A failure the *model* should see and can act on — a bad argument, a missing
    /// meeting, a store that isn't there — rather than a JSON-RPC error, which most
    /// clients surface to the user as "the server is broken" and never show the model
    /// at all. Protocol errors are reserved for genuine protocol faults.
    static func toolFailure(_ text: String) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(true),
        ])
    }

    private static func error(_ code: Int, _ message: String) -> JSONValue {
        .object(["code": .int(code), "message": .string(message)])
    }

    private func response(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func response(id: JSONValue, error: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": error])
    }

    /// Encoding a response can only fail on something unrepresentable, which none of
    /// the shapes above are — but a helper that traps mid-session takes the client's
    /// whole conversation with it, so the last resort is a hand-built error line.
    private func encode(_ value: JSONValue) -> Data {
        (try? value.encoded())
            ?? Data(#"{"error":{"code":-32603,"message":"Internal error"},"id":null,"jsonrpc":"2.0"}"#.utf8)
    }
}
