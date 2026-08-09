import Foundation
import OSLog

/// Moves Cheerio's entire Application Support container from the old bundle
/// identifier (``AudioStorage/legacyBundleIdentifier``, `app.cheerio.mac`) to the new
/// one (``AudioStorage/appBundleIdentifier``, `co.obvios.cheerio.mac`) in a single
/// rename, so every meeting, every enrolled speaker's voice sample, and the SwiftData
/// store itself survive the identifier change untouched.
///
/// Must run, and finish, before anything opens the store or resolves a meeting's
/// audio path — moving the directory out from under an already-open SQLite file
/// would corrupt it, and resolving a path against the wrong (empty) container reads
/// as data loss even though nothing was lost. `CheerioApp.init` calls
/// ``migrateIfNeeded()`` first thing, ahead of constructing its `ModelConfiguration`.
/// This is unrelated to ``StorageMigration``, which relocates individual meetings'
/// audio out of the *shared* Application Support root into whichever container this
/// migration leaves as current — that one runs later, inside a `.task`, once a
/// `ModelContext` exists, and is unaffected by this one.
///
/// A same-volume `FileManager.moveItem` is a rename: atomic, and it either lands
/// whole or not at all — there is no partially-moved state to detect or clean up.
public enum BundleIdentifierMigration {
    private static let log = Logger(subsystem: AudioStorage.appBundleIdentifier, category: "BundleIdentifierMigration")

    /// What a migration attempt decided.
    public enum Outcome: Equatable, Sendable {
        /// No old-identifier directory exists. Covers two different histories that
        /// require the identical response — do nothing, the new container is already
        /// the right one to use — a genuinely fresh install, and a machine that
        /// already migrated on an earlier launch and has since removed the old
        /// directory (there's nothing left to distinguish the two cases by, and
        /// nothing that needs to).
        case freshInstall
        /// The old directory was renamed into the new location.
        case migrated
        /// Both directories exist already. Neither is touched: the new one may hold
        /// data written since the identifier changed (a second migrated launch,
        /// concurrently or since), and the old one is not this migration's to
        /// discard. The caller opens the new container, as it always does.
        case bothExist
        /// The old directory exists, the new one doesn't, and the rename failed —
        /// permissions or some other I/O error; a same-volume rename doesn't fail for
        /// being cross-volume. The caller should keep operating against the *old*
        /// identifier for this launch (see ``AudioStorage/setContainerOverride(_:)``)
        /// rather than open an empty new container and present that as the library.
        case failed
    }

    /// The testable core: takes the shared Application Support directory and both
    /// identifiers as parameters instead of reaching for
    /// `.applicationSupportDirectory` and `Bundle.main` itself, so a test can point it
    /// at a scratch directory instead of touching `~/Library/Application Support`.
    @discardableResult
    public static func migrate(
        sharedApplicationSupport: URL,
        oldBundleIdentifier: String = AudioStorage.legacyBundleIdentifier,
        newBundleIdentifier: String = AudioStorage.appBundleIdentifier,
        fileManager: FileManager = .default
    ) -> Outcome {
        let old = sharedApplicationSupport.appending(path: oldBundleIdentifier, directoryHint: .isDirectory)
        let new = sharedApplicationSupport.appending(path: newBundleIdentifier, directoryHint: .isDirectory)

        guard fileManager.fileExists(atPath: old.path) else { return .freshInstall }
        guard !fileManager.fileExists(atPath: new.path) else {
            log.notice(
                "Both \(oldBundleIdentifier, privacy: .public) and \(newBundleIdentifier, privacy: .public) containers exist; leaving both alone."
            )
            return .bothExist
        }

        do {
            try fileManager.moveItem(at: old, to: new)
            log.notice(
                "Moved the Application Support container from \(oldBundleIdentifier, privacy: .public) to \(newBundleIdentifier, privacy: .public)."
            )
            return .migrated
        } catch {
            // Nothing prevents two Cheerio processes launching at once — this doc
            // comment already says so — so the guards above and this `moveItem` are
            // not one atomic step: another launch can win the identical rename in the
            // gap between them. When that's what happened, `old` is gone and `new` now
            // holds the migrated container; misreading that as `.failed` would set the
            // caller's container override back to the identifier that no longer has
            // anything at it, and `applicationSupport()` would silently recreate an
            // empty directory there instead of using the container the other launch
            // just finished populating. Only when `old` is *still* there — a genuine
            // failure, not a lost race — does this report `.failed`.
            if !fileManager.fileExists(atPath: old.path), fileManager.fileExists(atPath: new.path) {
                log.notice(
                    "Lost the migration race to another launch; \(newBundleIdentifier, privacy: .public) is already the current container."
                )
                return .migrated
            }
            log.error(
                "Couldn't move the Application Support container to the new bundle identifier; the old one stays current for this launch: \(error)"
            )
            return .failed
        }
    }

    /// The production entry point: resolves the real shared Application Support
    /// directory and migrates it. Call exactly once, before anything else in the app
    /// touches Application Support.
    @discardableResult
    public static func migrateIfNeeded() -> Outcome {
        do {
            return migrate(sharedApplicationSupport: try AudioStorage.sharedApplicationSupport())
        } catch {
            log.error("Couldn't resolve the shared Application Support directory: \(error)")
            return .failed
        }
    }
}
