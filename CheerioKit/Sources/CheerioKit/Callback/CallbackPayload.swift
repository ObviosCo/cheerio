import Foundation

/// Assembles what the transcript-ready callback (issue #26) needs to hand a
/// subprocess: the `MeetingExport` written to a file, plus the environment
/// entries that point at it. Deliberately ignorant of `Process` — the app target
/// runs the command, this only prepares what it runs with, so the assembly logic
/// stays usable from anywhere `CheerioKit` links, including a future bundled MCP
/// server (see the epic, #22) that will never spawn a subprocess itself.
public enum CallbackPayload {
    /// What one callback invocation needs, once assembled.
    public struct Prepared: Sendable, Equatable {
        /// `CHEERIO_MEETING_ID`, `CHEERIO_MEETING_KIND`, `CHEERIO_TITLE`, and
        /// `CHEERIO_EXPORT_PATH` — the env entries the runner overlays onto its own
        /// environment before launching the command. Never the full environment:
        /// merging in `PATH` and friends is the runner's job, not this one's.
        public let environment: [String: String]
        /// Where the export JSON was written — the same value as
        /// `environment["CHEERIO_EXPORT_PATH"]`, exposed directly so callers don't
        /// have to round-trip it through the dictionary.
        public let fileURL: URL
        /// The exact bytes written to `fileURL`, so the runner can pipe the same
        /// payload to the command's stdin without reading the file back.
        public let jsonData: Data
    }

    /// Subdirectory of Application Support the export JSON lands in.
    ///
    /// Retention: one file per *invocation*, named `<meeting>.<invocation>.json`,
    /// left in place rather than deleted after the callback runs. Naming by
    /// meeting alone isn't enough — callbacks run detached, and the "run now"
    /// button can fire the same meeting again while the previous command is still
    /// working, so a second atomic write would swap the file out from under a
    /// command that hasn't opened `CHEERIO_EXPORT_PATH` yet. That would break the
    /// documented contract that the file holds exactly the bytes piped to stdin.
    /// A fresh invocation UUID per ``prepare(export:in:)`` gives every run its own
    /// immutable file. Files therefore accumulate per invocation, not per meeting;
    /// they're still tiny — a meeting's JSON export runs from a few KB to the low
    /// hundreds, not megabytes — and having the last several on disk is actively
    /// useful when a user is debugging their command against a real payload.
    /// Nothing purges this folder automatically; if that ever needs to change, it
    /// belongs next to `AudioRetentionService` rather than as a second, unrelated
    /// cleanup policy.
    private static let folderName = "Callbacks"

    /// Where `prepare(export:)` writes unless a caller overrides it. Exposed so
    /// tests can assert against it without hardcoding the path, while still
    /// defaulting production callers to the real location.
    public static func defaultDirectory() throws -> URL {
        try AudioStorage.applicationSupport().appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Writes `export`'s JSON to `directory` (or ``defaultDirectory()``) and builds
    /// the environment entries that point at it.
    ///
    /// Each call writes a file nobody else will touch — see ``folderName`` for why
    /// the name carries a per-invocation UUID and not just the meeting's.
    ///
    /// - Parameter directory: Override for tests, so they don't write into the
    ///   shared Application Support directory a real app run uses.
    public static func prepare(export: MeetingExport, in directory: URL? = nil) throws -> Prepared {
        let directory = try directory ?? defaultDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let invocationID = UUID()
        let fileURL = directory.appending(path: "\(export.uuid.uuidString).\(invocationID.uuidString).json")
        let data = try MeetingExport.makeJSONEncoder().encode(export)
        try data.write(to: fileURL, options: .atomic)

        let environment: [String: String] = [
            "CHEERIO_MEETING_ID": export.uuid.uuidString,
            "CHEERIO_MEETING_KIND": export.kind.rawValue,
            "CHEERIO_TITLE": export.title,
            "CHEERIO_EXPORT_PATH": fileURL.path,
        ]
        return Prepared(environment: environment, fileURL: fileURL, jsonData: data)
    }
}
