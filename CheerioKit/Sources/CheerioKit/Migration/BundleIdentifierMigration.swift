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
/// The whole move is a single same-volume `FileManager.moveItem` — a rename,
/// atomic, landing whole or not at all — even when the new identifier's directory
/// already exists without a store of its own (issue #126: the bundled MCP helper
/// can leave exactly that behind by resolving the new container's path before the
/// app has ever launched). A store-less directory at the new location isn't a
/// library by definition, so it's moved aside first rather than merged into item
/// by item — see ``migrate(sharedApplicationSupport:oldBundleIdentifier:newBundleIdentifier:fileManager:)``
/// for why a destination-level merge can't make the same all-or-nothing guarantee
/// this rename can.
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
        /// The old directory became the new container by a single atomic rename —
        /// after moving a store-less directory that already occupied the new
        /// location out of the way first, if there was one. `.migrated` always
        /// means the *entire* old container is now at the new location: nothing
        /// from `old` was left behind, skipped, or partially merged.
        case migrated
        /// Both containers hold a SwiftData store already. Neither is touched: the
        /// new one holds data written since the identifier changed (a second
        /// migrated launch, concurrently or since, or a real second history), and
        /// the old one is not this migration's to discard. The caller opens the new
        /// container, as it always does.
        case bothExist
        /// The move failed — permissions or some other I/O error, either setting a
        /// pre-existing store-less directory aside or performing the rename itself.
        /// Either way `old` has not been touched: both are attempted before
        /// anything is taken out of `old`, so a failure at either point leaves it
        /// exactly as it was, and the caller can safely keep operating against the
        /// *old* identifier for this launch (see
        /// ``AudioStorage/setContainerOverride(_:)``) rather than open an empty or
        /// partially-set-up new container and present that as the library. The next
        /// launch simply retries the whole thing.
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
    /// directory sitting at `new` for this function to trip over.
    ///
    /// When that's the situation, this doesn't merge `old`'s items into the
    /// existing `new` directory one at a time. An item-by-item merge can only ever
    /// report success or failure for the *whole* merge by inspecting what it did
    /// after the fact — and a destination-name collision (the new directory already
    /// has, say, a `Meetings` folder of its own) has no safe resolution at that
    /// level: skip the colliding item and the old data behind it becomes
    /// unreachable through the container `.migrated` says is now current, but
    /// clobber it and something the new directory already owned is gone instead.
    /// Worse, a real half-moved failure (some items relocated, then an error) can
    /// leave `default.store` already moved to `new` while its own `Meetings`
    /// folder is still sitting in `old` — at which point falling back to the *old*
    /// identifier on `.failed`, as this type has always done, would be actively
    /// wrong, since the store that fallback expects to be there just left.
    ///
    /// Instead, a store-less `new` is moved aside to a sibling directory first —
    /// out of the way entirely, not merged from — so the proven whole-directory
    /// rename can run unchanged, exactly as it would against a `new` that never
    /// existed. `.migrated` then keeps meaning what it always meant: the entire
    /// former `old` is now at `new`. Only after that rename has *fully* succeeded
    /// does anything look at the set-aside directory again, to opportunistically
    /// merge back whatever in it doesn't collide with what just landed — at most
    /// helper-created crumbs, per the scenario above, never anything the rename
    /// itself depended on. Whatever's left in the set-aside directory after that
    /// (a genuine collision, most plausibly) is left on disk rather than deleted,
    /// named for what it is, for manual inspection.
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

        // Set aside before touching `old` at all — a store-less `new` might not
        // even be there (the common case), but when it is, this has to happen
        // first: nothing below may take anything out of `old` until the rename's
        // destination is provably clear, or a failure partway through would no
        // longer leave `old` untouched.
        var setAside: URL?
        do {
            if fileManager.fileExists(atPath: new.path) {
                let destination = sharedApplicationSupport.appending(
                    path: "\(newBundleIdentifier).pre-migration-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
                try fileManager.moveItem(at: new, to: destination)
                setAside = destination
            }

            try fileManager.moveItem(at: old, to: new)
        } catch {
            // Nothing prevents two Cheerio processes launching at once — this doc
            // comment already says so — so the guards above and the moves
            // themselves are not one atomic step: another launch can win the
            // identical migration in the gap between them. When that's what
            // happened, `old` is gone and `new` now holds a store; misreading that
            // as `.failed` would set the caller's container override back to the
            // identifier that no longer has anything at it, and
            // `applicationSupport()` would silently recreate an empty directory
            // there instead of using the container the other launch just finished
            // populating. Only when `old` is *still* there — a genuine failure —
            // does this report `.failed`. `old` is guaranteed to be exactly that
            // (untouched) in every other failure mode: setting `new` aside throwing
            // never reaches the rename, and the rename itself is one atomic step.
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

        log.notice(
            "Moved the Application Support container from \(oldBundleIdentifier, privacy: .public) to \(newBundleIdentifier, privacy: .public)."
        )
        if let setAside {
            mergeSetAsideRemnants(setAside, into: new, fileManager: fileManager)
        }
        return .migrated
    }

    /// Opportunistically folds whatever was set aside back into the now-migrated
    /// `new`, once the rename that made `new` the real container has already
    /// fully succeeded — this can only ever improve on leaving those items
    /// quarantined, never break anything the rename already landed, since it
    /// never overwrites a name that's already there.
    ///
    /// Best-effort throughout: nothing here throws, because by the time this
    /// runs the migration itself already succeeded and reporting `.failed` for a
    /// leftover crumb that didn't make it back would be wrong. Whatever doesn't
    /// merge — a genuine name collision, most plausibly, since anything here was
    /// at most helper-created before the rename ran — stays in the set-aside
    /// directory, which is left on disk rather than deleted, for someone to
    /// look at by hand.
    private static func mergeSetAsideRemnants(_ setAside: URL, into new: URL, fileManager: FileManager) {
        guard let items = try? fileManager.contentsOfDirectory(atPath: setAside.path) else { return }
        for name in items {
            let destination = new.appending(path: name)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.moveItem(at: setAside.appending(path: name), to: destination)
        }

        guard let remaining = try? fileManager.contentsOfDirectory(atPath: setAside.path) else { return }
        if remaining.isEmpty {
            try? fileManager.removeItem(at: setAside)
        } else {
            log.notice(
                "\(remaining.count, privacy: .public) item(s) set aside during migration couldn't be merged back — left at \(setAside.path, privacy: .public) for manual review."
            )
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
