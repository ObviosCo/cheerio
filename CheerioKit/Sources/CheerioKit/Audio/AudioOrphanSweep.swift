import Foundation
import OSLog
import SwiftData

/// Removes meeting-audio directories nothing in the store points at anymore.
///
/// `MeetingDeletion.delete(meetingID:container:)` already tries to remove a
/// meeting's audio directory itself, right after the row is gone — but that
/// removal is best-effort, and a failure there (disk full, permissions, a crash
/// mid-delete) previously had nowhere to be retried: `AudioRetentionService.purge`
/// only ever discovers a path by reading `Meeting.audioDirectory` off a
/// *surviving* row, so once the row that named a directory is gone, nothing else
/// in the app would ever look at that directory again. This is the retry: it
/// walks the directories `AudioStorage` actually writes meetings into and removes
/// exactly the ones no live `Meeting` still names.
public enum AudioOrphanSweep {
    private static let log = Logger(subsystem: "app.cheerio.mac", category: "AudioOrphanSweep")

    /// Call at launch, alongside `StorageMigration` and the retention purge —
    /// the same "clean up whatever an interrupted previous run left behind"
    /// moment.
    ///
    /// Conservative on purpose: an entry only qualifies for removal if its name
    /// is exactly a UUID — what `AudioStorage.makeMeetingDirectory()` mints — and
    /// it's an actual directory. Anything else found here (a future format, a
    /// stray file, something dropped in by another process) is left alone rather
    /// than guessed at.
    ///
    /// `meetingsDirectory` defaults to `AudioStorage.meetingsDirectoryURL` and
    /// exists as a parameter so tests can point it at a directory that isn't the
    /// real Application Support container. Returns how many directories were
    /// removed, so a caller can log it; a missing folder (nothing has recorded
    /// audio yet) is 0, not an error.
    @discardableResult
    public static func sweep(
        context: ModelContext,
        meetingsDirectory: () throws -> URL = AudioStorage.meetingsDirectoryURL
    ) throws -> Int {
        let root = try meetingsDirectory()
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            )
        else {
            return 0
        }

        let owned = Set(try context.fetch(FetchDescriptor<Meeting>()).compactMap(\.audioDirectory))

        var removed = 0
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }

            // Derived from `root`, not a re-declared "Meetings" literal — this has
            // to match exactly what `AudioStorage.makeMeetingDirectory()` wrote
            // onto `Meeting.audioDirectory`, and the one place that already knows
            // that folder's name is the root this was just handed.
            let relativePath = "\(root.lastPathComponent)/\(entry.lastPathComponent)"
            guard !owned.contains(relativePath) else { continue }

            do {
                try FileManager.default.removeItem(at: entry)
                removed += 1
                log.notice("Removed orphaned audio directory \(entry.lastPathComponent, privacy: .public)")
            } catch {
                log.error(
                    "Couldn't remove orphaned audio directory \(entry.lastPathComponent, privacy: .public): \(error)"
                )
            }
        }
        return removed
    }
}
