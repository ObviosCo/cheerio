import Foundation
import OSLog

/// Moves Cheerio's entire Application Support container from the old bundle
/// identifier (``AudioStorage/legacyBundleIdentifier``, `app.cheerio.mac`) to the new
/// one (``AudioStorage/appBundleIdentifier``, `co.obvios.cheerio.mac`), so every
/// meeting, every enrolled speaker's voice sample, and the SwiftData store itself
/// survive the identifier change untouched.
///
/// Must run, and finish, before anything opens the store or resolves a meeting's
/// audio path — moving data out from under an already-open SQLite file would
/// corrupt it, and resolving a path against the wrong (empty) container reads as
/// data loss even though nothing was lost. `CheerioApp.init` calls
/// ``migrateIfNeeded()`` first thing, ahead of constructing its `ModelConfiguration`.
/// This is unrelated to ``StorageMigration``, which relocates individual meetings'
/// audio out of the *shared* Application Support root into whichever container this
/// migration leaves as current — that one runs later, inside a `.task`, once a
/// `ModelContext` exists, and is unaffected by this one.
///
/// The common case is a single same-volume `FileManager.moveItem` — a rename,
/// atomic, landing whole or not at all. When the new identifier's directory
/// already exists without a store of its own (issue #126: the bundled MCP helper
/// can resolve, and thereby create a bare parent for, the new container's path
/// before the app has ever launched), a whole-directory rename can't land on top
/// of it, so this instead moves the old container's contents into the existing
/// one item by item — see ``migrate(sharedApplicationSupport:oldBundleIdentifier:newBundleIdentifier:fileManager:)``.
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
        /// The old directory's contents were moved into the new location — either by
        /// renaming the whole directory (the new one didn't exist yet) or by moving
        /// its contents in item by item (the new one already existed, empty or not,
        /// but held no store of its own — see ``migrate(sharedApplicationSupport:oldBundleIdentifier:newBundleIdentifier:fileManager:)``).
        case migrated
        /// Both containers hold a SwiftData store already. Neither is touched: the
        /// new one holds data written since the identifier changed (a second
        /// migrated launch, concurrently or since, or a real second history), and
        /// the old one is not this migration's to discard. The caller opens the new
        /// container, as it always does.
        case bothExist
        /// The old directory exists, the new one holds no store, and the move
        /// failed — permissions or some other I/O error, or a partial item-by-item
        /// merge that stopped partway through. A same-volume move doesn't fail for
        /// being cross-volume. The caller should keep operating against the *old*
        /// identifier for this launch (see ``AudioStorage/setContainerOverride(_:)``)
        /// rather than open an empty (or partially-filled) new container and present
        /// that as the library. Idempotent either way: the next launch resumes,
        /// since an item already moved into the new location is skipped, not
        /// re-moved, next time.
        case failed
    }

    /// The testable core: takes the shared Application Support directory and both
    /// identifiers as parameters instead of reaching for
    /// `.applicationSupportDirectory` and `Bundle.main` itself, so a test can point it
    /// at a scratch directory instead of touching `~/Library/Application Support`.
    ///
    /// The both-exist verdict keys on a *store* at the new location
    /// (``AudioStorage/storeFileName``), not on the new directory merely existing.
    /// A bare or store-less new directory does not mean "another launch already has
    /// this" — it means something else created it first, which in production was the
    /// bundled MCP helper resolving a store path before the app it ships with had
    /// ever run (issue #126): `MeetingStore.resolveStoreURL` reads
    /// ``AudioStorage/containerURL(bundleIdentifier:)`` for the current identifier
    /// before falling back to the old one, and that read alone left an empty
    /// directory sitting at `new` for this function to trip over. When that's the
    /// situation, the old container's contents still belong here, so this migrates
    /// them in rather than walking away and stranding a whole library under the old
    /// identifier next to an app that now presents as empty.
    @discardableResult
    public static func migrate(
        sharedApplicationSupport: URL,
        oldBundleIdentifier: String = AudioStorage.legacyBundleIdentifier,
        newBundleIdentifier: String = AudioStorage.appBundleIdentifier,
        fileManager: FileManager = .default
    ) -> Outcome {
        let old = sharedApplicationSupport.appending(path: oldBundleIdentifier, directoryHint: .isDirectory)
        let new = sharedApplicationSupport.appending(path: newBundleIdentifier, directoryHint: .isDirectory)
        let newStore = new.appending(path: AudioStorage.storeFileName)

        guard fileManager.fileExists(atPath: old.path) else { return .freshInstall }
        guard !fileManager.fileExists(atPath: newStore.path) else {
            log.notice(
                "Both \(oldBundleIdentifier, privacy: .public) and \(newBundleIdentifier, privacy: .public) containers hold a store; leaving both alone."
            )
            return .bothExist
        }

        do {
            // The plain rename is preferred whenever it's available — one atomic
            // step, same as before — and only falls back to an item-by-item merge
            // when something already occupies `new`, since a rename can't land a
            // directory on top of one that's already there.
            if fileManager.fileExists(atPath: new.path) {
                try mergeContents(of: old, into: new, fileManager: fileManager)
            } else {
                try fileManager.moveItem(at: old, to: new)
            }
            log.notice(
                "Moved the Application Support container from \(oldBundleIdentifier, privacy: .public) to \(newBundleIdentifier, privacy: .public)."
            )
            return .migrated
        } catch {
            // Nothing prevents two Cheerio processes launching at once — this doc
            // comment already says so — so the guards above and the move itself are
            // not one atomic step: another launch can win the identical migration in
            // the gap between them. When that's what happened, `old` is gone and
            // `new` now holds a store; misreading that as `.failed` would set the
            // caller's container override back to the identifier that no longer has
            // anything at it, and `applicationSupport()` would silently recreate an
            // empty directory there instead of using the container the other launch
            // just finished populating. Only when `old` is *still* there — a genuine
            // failure, or a merge that stopped partway through — does this report
            // `.failed`.
            if !fileManager.fileExists(atPath: old.path), fileManager.fileExists(atPath: newStore.path) {
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

    /// Moves every item directly inside `old` into `new`, one item at a time,
    /// for when a whole-directory rename isn't available because `new` already
    /// exists — empty, holding an unrelated file, or (per ``migrate`` above)
    /// anything short of a store, since a store there would already have
    /// returned ``Outcome/bothExist`` before this is ever called.
    ///
    /// Never overwrites anything already at the destination: an item with a name
    /// already present in `new` is left in `old` untouched rather than moved, on
    /// the chance it's either another launch's concurrent progress on this same
    /// merge or simply not this migration's to touch. `old` is removed only once
    /// it's been fully emptied — leaving a colliding item behind keeps it around
    /// for the situation to be resolved by hand or by a later, non-colliding
    /// launch, rather than silently discarding data that didn't make it across.
    ///
    /// A single item's move failing partway through aborts the whole merge and
    /// throws, exactly like a whole-directory rename failing — the caller's
    /// `catch` reports `.failed` and leaves `old` as the source of truth for this
    /// launch. That's safe to retry: an item already moved into `new` is skipped,
    /// not re-moved, the next time this runs.
    private static func mergeContents(of old: URL, into new: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: new.path) {
            try fileManager.createDirectory(at: new, withIntermediateDirectories: true)
        }
        for name in try fileManager.contentsOfDirectory(atPath: old.path) {
            let destination = new.appending(path: name)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.moveItem(at: old.appending(path: name), to: destination)
        }
        if let remaining = try? fileManager.contentsOfDirectory(atPath: old.path), remaining.isEmpty {
            try? fileManager.removeItem(at: old)
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
