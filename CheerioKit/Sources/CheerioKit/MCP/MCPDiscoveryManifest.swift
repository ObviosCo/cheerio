import Foundation

/// Advertises the bundled MCP server where a local agent can find it on its own.
///
/// `MCPClientSetup` covers the human path: Settings shows config text, the user pastes
/// it. This covers the agent path — a small JSON manifest at a fixed, documented,
/// per-user location (`~/Library/Application Support/Cheerio/mcp-server.json`) saying
/// what the server is called, where the helper executable lives right now, and that it
/// speaks stdio. An agent that has read the README can go from "is Cheerio installed?"
/// to a working connection without a person in the loop.
///
/// The direction of trust is the same as `MCPClientSetup`'s and just as deliberate:
/// Cheerio writes only into this location of its own, never into another app's config
/// file. Advertising is Cheerio saying "here I am"; it is never Cheerio deciding, on an
/// agent's behalf, that the agent should connect.
///
/// Surveyed before inventing (2026-08): the MCP ecosystem has no convention for a
/// locally installed app advertising a stdio server. The official registry
/// (`registry.modelcontextprotocol.io`) catalogues *published* servers over the
/// network, and SEP-2127's `.well-known` Server Cards cover HTTP servers only. The
/// manifest borrows the registry's `server.json` vocabulary where it fits (`name`,
/// `description`, `version`, a `transport` with `"type": "stdio"`) so the words mean
/// what an MCP-literate reader expects, and adds the one thing a local manifest needs
/// that a registry entry can't carry: the absolute path of the installed executable.
///
/// The path is keyed on the product name, not the bundle identifier, so finding it
/// never requires knowing `co.obvios.cheerio.mac` — the README alone is enough. It is
/// refreshed on every app launch, so it tracks wherever the app actually is; the
/// staleness contract for readers is in ``Contents/command``'s doc comment.
public enum MCPDiscoveryManifest {
    /// Directory under `~/Library/Application Support` holding the manifest. Cheerio's
    /// own data container is named by bundle identifier and stays that way; this is a
    /// second, deliberately human-readable directory because its audience is other
    /// software following written documentation, not Cheerio itself.
    public static let directoryName = "Cheerio"

    /// The manifest's filename. Fixed rather than derived from the server name so the
    /// README can state the full path as a literal string.
    public static let fileName = "mcp-server.json"

    /// What the manifest says. `Codable` both ways so tests — and any Swift-side agent
    /// tooling — can read back exactly what was written.
    public struct Contents: Codable, Equatable, Sendable {
        public struct Transport: Codable, Equatable, Sendable {
            public var type: String

            public init(type: String) {
                self.type = type
            }
        }

        /// `MCPClientSetup.serverName` — the same name Settings tells a user to
        /// register, so the manual and automatic paths can't drift apart.
        public var name: String

        public var description: String

        /// The app's marketing version, when the writer knows it. Optional because
        /// the manifest is written from `Bundle.main` metadata that a development
        /// build may not carry.
        public var version: String?

        /// Absolute path of the helper executable, launchable as-is with no
        /// arguments. This is also the staleness signal: the manifest is rewritten on
        /// every Cheerio launch, so if nothing exists at this path anymore, Cheerio
        /// was moved or uninstalled and hasn't run since — readers should treat the
        /// whole manifest as void rather than trusting any other field.
        public var command: String

        public var transport: Transport

        /// When the manifest was last written. Freshness metadata for a reader that
        /// wants it; existence of `command` is the authoritative validity check.
        public var updatedAt: Date

        public init(
            name: String, description: String, version: String?, command: String,
            transport: Transport, updatedAt: Date
        ) {
            self.name = name
            self.description = description
            self.version = version
            self.command = command
            self.transport = transport
            self.updatedAt = updatedAt
        }
    }

    /// One sentence for an agent deciding whether this server is relevant, so it reads
    /// like a tool description rather than marketing copy.
    public static let serverDescription =
        "Read-only access to Cheerio meeting transcripts, notes, and action items over MCP (stdio)."

    /// What a refresh did, for the caller's log line.
    public enum Outcome: Equatable, Sendable {
        case written(URL)
        /// No helper exists at the expected place inside this copy of the app, so
        /// there is nothing true to advertise. The manifest on disk — possibly
        /// written by an intact copy elsewhere — is left alone rather than
        /// overwritten or deleted.
        case helperMissing
    }

    /// The manifest's location under a given Application Support directory.
    ///
    /// Takes the parent as a parameter for the same reason `MCPClientSetup.helperURL`
    /// takes the bundle: tests point it at a temporary directory instead of the real
    /// `~/Library`.
    public static func manifestURL(applicationSupport: URL) -> URL {
        applicationSupport.appending(path: directoryName).appending(path: fileName)
    }

    /// The real per-user location, `~/Library/Application Support/Cheerio/mcp-server.json`.
    public static func defaultManifestURL() throws -> URL {
        manifestURL(
            applicationSupport: try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ))
    }

    /// Writes the manifest, or declines because there's nothing true to write.
    ///
    /// Unconditionally rewritten when the helper exists — even if only `updatedAt`
    /// would change — because the whole point is tracking where the app is *now*, and
    /// a fresh timestamp is what tells a reader the advertisement was recently
    /// confirmed. The write is atomic (temp file + rename) so an agent reading
    /// concurrently sees the old manifest or the new one, never a torn file.
    public static func refresh(
        helperURL: URL,
        manifestURL: URL,
        version: String?,
        now: Date = .now
    ) throws -> Outcome {
        let helperPath = helperURL.path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            return .helperMissing
        }

        let contents = Contents(
            name: MCPClientSetup.serverName,
            description: serverDescription,
            version: version,
            command: helperPath,
            transport: Contents.Transport(type: "stdio"),
            updatedAt: now
        )

        let encoder = JSONEncoder()
        // Deterministic and diffable: an agent may cache or checksum the file, and a
        // person debugging a connection will read it in a pager.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(contents)
        data.append(UInt8(ascii: "\n"))

        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
        return .written(manifestURL)
    }

    /// The app's launch hook: advertise the helper inside this copy of the bundle at
    /// the real per-user location.
    public static func refreshAtLaunch(appBundle: URL, version: String?) throws -> Outcome {
        try refresh(
            helperURL: MCPClientSetup.helperURL(appBundle: appBundle),
            manifestURL: defaultManifestURL(),
            version: version
        )
    }
}
