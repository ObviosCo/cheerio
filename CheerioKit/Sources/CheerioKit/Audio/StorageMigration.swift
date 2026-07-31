import Foundation
import OSLog
import SwiftData

/// Moves data out of the shared Application Support directory and into Cheerio's
/// own container.
///
/// Early unsandboxed builds wrote `default.store` and `Meetings/<uuid>/` directly
/// into `~/Library/Application Support`, which is shared between apps — and
/// already contained an unrelated app's `Meetings` folder. This relocates our data
/// and is careful to touch **only** paths we know we created.
public enum StorageMigration {
    private static let log = Logger(subsystem: "app.cheerio.mac", category: "StorageMigration")
    private static let storeFileNames = ["default.store", "default.store-shm", "default.store-wal"]

    /// Relocates the SwiftData store. Must run *before* the `ModelContainer` opens,
    /// or SQLite will hold the old files open.
    public static func migrateStoreIfNeeded() {
        do {
            let source = try AudioStorage.sharedApplicationSupport()
            let destination = try AudioStorage.applicationSupport()
            let fileManager = FileManager.default

            // The store's sidecar files must travel with it, so bail out entirely if
            // the destination already has a store — a half-merged pair would be worse
            // than leaving the old one alone.
            let destinationStore = destination.appending(path: storeFileNames[0])
            guard !fileManager.fileExists(atPath: destinationStore.path) else { return }
            guard fileManager.fileExists(atPath: source.appending(path: storeFileNames[0]).path) else { return }

            for name in storeFileNames {
                let old = source.appending(path: name)
                guard fileManager.fileExists(atPath: old.path) else { continue }
                try fileManager.moveItem(at: old, to: destination.appending(path: name))
            }
            log.notice("Moved the store into \(destination.lastPathComponent, privacy: .public)")
        } catch {
            // A failed move leaves the old store in place, so the app still opens —
            // against the old location, since the new one has no store.
            log.error("Store migration failed: \(error)")
        }
    }

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

                try fileManager.createDirectory(
                    at: new.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: old, to: new)
                moved += 1
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
