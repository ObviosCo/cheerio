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
    private static let log = Logger(subsystem: "app.cheerio.mac", category: "StorageMigration")

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
}
