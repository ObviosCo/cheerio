import Foundation
import SwiftData

/// Opens the app's SwiftData store from a *second* process, read-only — the store
/// half of the bundled MCP helper (issue #28).
///
/// The app owns this store and may be writing to it while the helper reads. That is
/// safe because SwiftData sits on Core Data's SQLite store in WAL mode, where a
/// reader takes a snapshot and never blocks or is blocked by the single writer. The
/// helper does not participate in the app's change notifications, so what it reads is
/// "the store as of the moment it opened its context" — for answering "what did we
/// decide on Tuesday?" that is exactly right, and for a recording in progress it
/// means the transcript-so-far, not a live tail.
///
/// Read-only here means two independent things, both required:
/// - `allowsSave: false` on the ``ModelConfiguration``, so the store is opened
///   without write intent, and
/// - no code path in the helper mutating a fetched model. That second one is not
///   automatic — see ``Meeting/readOnlyExport(ownerNames:)`` for the one place the
///   model layer would otherwise write on a mere property read.
public enum MeetingStore {
    /// Environment variable that points the helper at a different store file.
    ///
    /// The reason this exists is testing: the real store is the user's meeting
    /// history, and pointing a smoke test or a bug report reproduction at a *copy*
    /// has to be possible without editing code or risking the original. It is
    /// deliberately an environment variable rather than an argument, because an MCP
    /// client launches the helper through a config file where `env` is a first-class
    /// field and argv often isn't.
    public static let storePathEnvironmentKey = "CHEERIO_STORE_PATH"

    /// Why the helper could not read a store, in terms a client can act on.
    ///
    /// Every case carries its own remedy, because the alternative — an MCP client
    /// surfacing `NSCocoaErrorDomain 134110` to whoever asked about last Tuesday's
    /// call — is indistinguishable from the tool being broken.
    public enum Failure: Error, CustomStringConvertible, Sendable, Equatable {
        /// No store file at the resolved path: Cheerio has never run, or it keeps its
        /// data somewhere else (the sandbox flag moves the container — see
        /// ARCHITECTURE.md).
        case noStore(path: String)
        /// The file is there but this build can't open it. Overwhelmingly the
        /// migration case: the store was written by a schema this helper predates, or
        /// by an older one that needs additive columns adding — and adding them is a
        /// *write*, which a read-only opener is not allowed to do. Launching the app
        /// once resolves it, because the app opens the same store writably.
        case unreadable(path: String, detail: String)

        public var description: String {
            switch self {
            case .noStore(let path):
                """
                No Cheerio store at \(path). Launch Cheerio at least once so it creates one. \
                If Cheerio keeps its data elsewhere, set \(storePathEnvironmentKey) to the store file.
                """
            case .unreadable(let path, let detail):
                """
                Couldn't open the Cheerio store at \(path) read-only. This usually means the store's \
                schema doesn't match this helper's — launch the matching version of Cheerio once so it \
                can migrate the store, then retry. Underlying error: \(detail)
                """
            }
        }
    }

    /// The store the helper should read: ``storePathEnvironmentKey`` if set,
    /// otherwise the app's own store inside its Application Support container.
    ///
    /// Resolves without creating anything, unlike ``AudioStorage/storeURL()``, whose
    /// caller is the app and for whom a missing container is a thing to fix.
    public static func resolveStoreURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let override = environment[storePathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(filePath: override)
        }
        return try AudioStorage.containerURL().appending(path: AudioStorage.storeFileName)
    }

    /// Opens `url` read-only, or throws a ``Failure`` explaining what to do about it.
    ///
    /// Checks the file exists first rather than letting `ModelContainer` decide: a
    /// `ModelConfiguration` pointed at a missing file *creates* it, which for a
    /// read-only helper would mean silently answering "you have no meetings" out of a
    /// brand-new empty database it just laid down next to the real one.
    public static func openReadOnly(at url: URL) throws -> ModelContainer {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw Failure.noStore(path: url.path(percentEncoded: false))
        }
        do {
            return try ModelContainer(
                for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
                configurations: ModelConfiguration(url: url, allowsSave: false)
            )
        } catch {
            throw Failure.unreadable(path: url.path(percentEncoded: false), detail: Self.shortDetail(error))
        }
    }

    /// The readable part of a Core Data failure.
    ///
    /// Interpolating a `SwiftDataError` wrapping a `CocoaError` produces about two
    /// thousand characters of nested `userInfo`, three copies of the store path, and one
    /// clause that actually says what went wrong. The whole of it in a tool result is
    /// context spent to hide the answer, so pull out Core Data's own `reason` when it's
    /// there and cap the rest.
    private static func shortDetail(_ error: any Error) -> String {
        let text = "\(error)"
        if let range = text.range(of: "reason="),
            let end = text[range.upperBound...].range(of: ", ")?.lowerBound
                ?? text.range(of: "}", range: range.upperBound..<text.endIndex)?.lowerBound
        {
            let reason = text[range.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty { return reason }
        }
        return text.count > 300 ? "\(text.prefix(300))…" : text
    }
}
