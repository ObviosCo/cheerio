import Foundation
import OSLog
import SwiftData

/// Moves meeting audio out of the shared Application Support directory and into
/// Cheerio's own container.
///
/// Early unsandboxed builds wrote `Meetings/<uuid>/` directly into
/// `~/Library/Application Support`, which is shared between apps — and already
/// contained an unrelated app's `Meetings` folder. This relocates our data and is
/// careful to touch **only** paths we know we created.
///
/// There was a matching store migration; it's gone. It keyed off a `default.store` in
/// the shared directory, but that's SwiftData's *default* filename, so such a file is
/// as likely to belong to another unsandboxed app as to us — and moving it would both
/// break that app and hand us a database we can't open. Nothing established
/// provenance, the multi-file move wasn't atomic (a store that moved without its
/// `-wal` would then open every launch minus its uncheckpointed writes), and the
/// fallback its comment described didn't exist, since the app always opened the
/// container path regardless. The one store it was written for has long since moved,
/// so the whole thing was risk with nothing left to gain.
public enum StorageMigration {
    private static let log = Logger(subsystem: "co.obvios.cheerio.mac", category: "StorageMigration")

    /// Relocates each meeting's audio directory.
    ///
    /// Runs after the container is open so the set of directories comes from the
    /// meetings themselves — we never move a directory we didn't record, which
    /// matters because the old location is shared with another app.
    public static func migrateAudioIfNeeded(context: ModelContext) {
        do {
            let source = try AudioStorage.sharedApplicationSupport()
            let destination = try AudioStorage.applicationSupport()
            let fileManager = FileManager.default

            let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.audioDirectory != nil })
            var moved = 0
            for meeting in try context.fetch(descriptor) {
                guard let relativePath = meeting.audioDirectory else { continue }
                let old = source.appending(path: relativePath, directoryHint: .isDirectory)
                let new = destination.appending(path: relativePath, directoryHint: .isDirectory)
                guard !fileManager.fileExists(atPath: new.path),
                    fileManager.fileExists(atPath: old.path)
                else { continue }

                do {
                    try fileManager.createDirectory(
                        at: new.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: old, to: new)
                    moved += 1
                } catch {
                    // Per meeting, not per run: letting one stubborn directory reach the
                    // outer catch abandoned every meeting after it, and the same one
                    // would block them again on every future launch.
                    log.error(
                        "Couldn't move audio for \(relativePath, privacy: .public): \(error)"
                    )
                }
            }
            if moved > 0 {
                log.notice("Moved audio for \(moved, privacy: .public) meeting(s) into the app container")
            }

            // Remove the old Meetings folder only if it's now empty — if it isn't,
            // the remaining contents belong to somebody else.
            let oldMeetings = source.appending(path: "Meetings", directoryHint: .isDirectory)
            if let contents = try? fileManager.contentsOfDirectory(atPath: oldMeetings.path), contents.isEmpty {
                try? fileManager.removeItem(at: oldMeetings)
            }
        } catch {
            log.error("Audio migration failed: \(error)")
        }
    }

    /// Gives every meeting still missing one a ``Meeting/uuid``, and saves.
    ///
    /// ``Meeting/stableID`` backfills lazily, which is the right design for the app —
    /// but "lazily" means a meeting only gets an identifier once something asks for
    /// one, and before the bundled MCP helper nothing routinely did. A store carried
    /// forward from an earlier build can therefore hold a full history where every row
    /// has `uuid == nil`, and those rows are exactly the ones the helper cannot
    /// address: minting an identifier is a write, and the helper never writes. Doing
    /// it here, once, in the process that *is* allowed to write, is what turns "the
    /// MCP server can't see any of your old meetings" into a non-problem.
    ///
    /// Returns how many rows were given one, so a caller can log it. Idempotent: the
    /// second run fetches nothing and saves nothing.
    @discardableResult
    public static func backfillMeetingIDs(context: ModelContext) -> Int {
        do {
            let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.uuid == nil })
            let pending = try context.fetch(descriptor)
            guard !pending.isEmpty else { return 0 }
            // Accessing stableID is the assignment — see its documentation.
            for meeting in pending { _ = meeting.stableID }
            try context.save()
            log.notice("Assigned identifiers to \(pending.count, privacy: .public) meeting(s)")
            return pending.count
        } catch {
            // Not fatal: the app works without these, only the MCP helper's view of
            // pre-existing meetings is degraded, and it says so per meeting.
            log.error("Couldn't backfill meeting identifiers: \(error)")
            return 0
        }
    }
}
