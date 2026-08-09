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
/// this rename can, and for how two Cheerio processes racing the exact same
/// migration are handled generically rather than as one-off interleavings.
public enum BundleIdentifierMigration {
    private static let log = Logger(subsystem: AudioStorage.appBundleIdentifier, category: "BundleIdentifierMigration")

    /// How many times ``migrate(sharedApplicationSupport:oldBundleIdentifier:newBundleIdentifier:fileManager:)``
    /// re-reads the world and retries after a move throws, before concluding the
    /// failure is real rather than another launch racing the same migration.
    /// Small on purpose: a genuine race resolves within one or two attempts (the
    /// other launch finishes what it started), so this exists to absorb that, not
    /// to paper over a real, repeatable I/O failure — which throws identically on
    /// every attempt and so still reports `.failed` once the budget runs out.
    private static let maxMigrationAttempts = 3

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
        /// from `old` was left behind, skipped, or partially merged, regardless of
        /// whether this call performed the rename itself or lost the race to
        /// another launch that did.
        case migrated
        /// Both containers hold a SwiftData store already. Neither is touched: the
        /// new one holds data written since the identifier changed (a second
        /// migrated launch, concurrently or since, or a real second history), and
        /// the old one is not this migration's to discard. The caller opens the new
        /// container, as it always does.
        case bothExist
        /// Every retry was exhausted without the world ever settling into a
        /// recognized shape — a genuine, repeatable I/O error (permissions, most
        /// plausibly) throwing the same way on every attempt, since a transient
        /// race with another launch resolves within a couple of retries instead.
        /// `old` has not been touched in every path that reaches this: nothing is
        /// ever taken out of it until the rename that makes `new` current, which is
        /// one atomic step, so a failure setting a pre-existing store-less `new`
        /// aside or performing that rename always leaves `old` exactly as it was.
        /// The caller can safely keep operating against the *old* identifier for
        /// this launch (see ``AudioStorage/setContainerOverride(_:)``) rather than
        /// open an empty or partially-set-up new container and present that as the
        /// library. The next launch simply retries the whole thing from scratch.
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
    /// identifier on `.failed` would be actively wrong, since the store that
    /// fallback expects to be there just left.
    ///
    /// Instead, a store-less `new` is moved aside to a UUID-suffixed sibling first
    /// — out of the way entirely, not merged from — so the proven whole-directory
    /// rename can run unchanged, exactly as it would against a `new` that never
    /// existed. `.migrated` then keeps meaning what it always meant: the entire
    /// former `old` is now at `new`.
    ///
    /// Two Cheerio processes can launch at once, so every one of those two moves
    /// can race an identical attempt by another launch. Rather than special-case
    /// each interleaving that produces (set-aside racing set-aside, set-aside
    /// racing the rename, this launch's rename racing another's), a single move
    /// throwing anywhere in ``attemptMigration(sharedApplicationSupport:old:new:newStore:oldBundleIdentifier:newBundleIdentifier:fileManager:)``
    /// just asks for a retry: the next attempt re-reads `old` and `newStore` from
    /// scratch, with no memory of what the previous attempt assumed, and resolves
    /// to `.migrated` on its own if that fresh read shows another launch already
    /// finished. `.failed` only comes from every attempt in
    /// ``maxMigrationAttempts`` seeing the same stuck state and the same throw —
    /// which is what a real, repeatable failure looks like, as opposed to a race
    /// that clears within a couple of reads.
    ///
    /// Reconciling whatever a set-aside step produced is likewise keyed on
    /// observable state — "does `new` hold a store right now" — rather than on
    /// which attempt, or which launch, created a given sibling: see
    /// ``reconcileSetAsideSiblings(sharedApplicationSupport:newBundleIdentifier:fileManager:)``.
    /// That's what makes the lost-the-race branch above still clean up the very
    /// sibling *this* call created before losing, and what lets a much later,
    /// otherwise-unrelated launch sweep a sibling orphaned by a launch that set
    /// `new` aside and then genuinely failed the rename — nothing else would ever
    /// revisit that sibling, since the next successful attempt finds `new` simply
    /// absent and takes the direct-rename path with no reason to go looking for a
    /// UUID-suffixed directory nothing points it at.
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

        guard fileManager.fileExists(atPath: old.path) else {
            // A machine that migrated long ago, whose old directory is long gone,
            // can still have an orphaned set-aside sibling from a *failed* attempt
            // that ran before whichever attempt eventually succeeded. Nothing else
            // ever revisits that sibling once `old` is gone — the successful
            // attempt's own rename doesn't know it exists — so this unconditional
            // check is the one place guaranteed to run on every later launch.
            reconcileSetAsideSiblings(
                sharedApplicationSupport: sharedApplicationSupport, newBundleIdentifier: newBundleIdentifier,
                fileManager: fileManager
            )
            return .freshInstall
        }
        guard !fileManager.fileExists(atPath: newStore.path) else {
            log.notice(
                "Both \(oldBundleIdentifier, privacy: .public) and \(newBundleIdentifier, privacy: .public) containers hold a store; leaving both alone."
            )
            return .bothExist
        }

        for _ in 0..<maxMigrationAttempts {
            if let outcome = attemptMigration(
                sharedApplicationSupport: sharedApplicationSupport, old: old, new: new, newStore: newStore,
                oldBundleIdentifier: oldBundleIdentifier, newBundleIdentifier: newBundleIdentifier,
                fileManager: fileManager
            ) {
                return outcome
            }
        }
        log.error(
            "Gave up after \(maxMigrationAttempts, privacy: .public) attempts moving the Application Support container to the new bundle identifier; the old one stays current for this launch."
        )
        return .failed
    }

    /// One attempt at the migration, reading `old` and `newStore`'s current state
    /// fresh rather than trusting anything decided earlier in the same call —
    /// nothing carries over between attempts except the count. Returns `nil` to
    /// ask ``migrate(sharedApplicationSupport:oldBundleIdentifier:newBundleIdentifier:fileManager:)``
    /// for another attempt: a thrown move here doesn't yet distinguish a genuine,
    /// repeatable failure from another launch having reached the same fork first,
    /// and re-reading state at the top of the *next* attempt is what tells them
    /// apart, not anything available at the point of the throw itself.
    private static func attemptMigration(
        sharedApplicationSupport: URL, old: URL, new: URL, newStore: URL,
        oldBundleIdentifier: String, newBundleIdentifier: String, fileManager: FileManager
    ) -> Outcome? {
        guard fileManager.fileExists(atPath: old.path) else {
            guard fileManager.fileExists(atPath: newStore.path) else {
                // `old` disappeared without `new` ever holding a store — not a
                // shape any launch racing this same migration produces (every
                // branch below only removes `old` in the same step that populates
                // `new`), and retrying can't bring `old` back. Reporting `.migrated`
                // here would mean opening a container that isn't actually a
                // library.
                return .failed
            }
            log.notice(
                "Lost the migration race to another launch; \(newBundleIdentifier, privacy: .public) is already the current container."
            )
            reconcileSetAsideSiblings(
                sharedApplicationSupport: sharedApplicationSupport, newBundleIdentifier: newBundleIdentifier,
                fileManager: fileManager
            )
            return .migrated
        }
        guard !fileManager.fileExists(atPath: newStore.path) else {
            // Both containers now hold a store — the same "leave both alone"
            // verdict as when this is true from the very start of `migrate`,
            // just discovered mid-race instead.
            return .bothExist
        }

        do {
            // Set aside before touching `old` at all — nothing below may take
            // anything out of `old` until the rename's destination is provably
            // clear, or a failure partway through would no longer leave `old`
            // untouched.
            if fileManager.fileExists(atPath: new.path) {
                let setAside = sharedApplicationSupport.appending(
                    path: "\(newBundleIdentifier).pre-migration-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
                try fileManager.moveItem(at: new, to: setAside)
            }
            try fileManager.moveItem(at: old, to: new)
        } catch {
            // A throw here means exactly one of two things: a genuine, repeatable
            // failure (permissions, most plausibly), or another launch reaching
            // this same fork first — moving `new` aside itself, or finishing the
            // whole rename — and leaving this attempt racing against a world that
            // no longer matches what it just read. The two are indistinguishable
            // from the throw alone, which is exactly why this never decides here:
            // asking for a retry lets the next attempt's fresh read resolve it.
            return nil
        }

        log.notice(
            "Moved the Application Support container from \(oldBundleIdentifier, privacy: .public) to \(newBundleIdentifier, privacy: .public)."
        )
        reconcileSetAsideSiblings(
            sharedApplicationSupport: sharedApplicationSupport, newBundleIdentifier: newBundleIdentifier,
            fileManager: fileManager
        )
        return .migrated
    }

    /// Sweeps every `<newBundleIdentifier>.pre-migration-*` sibling of `new` and
    /// folds whatever in each one doesn't collide back into `new`, once `new`
    /// actually holds a store.
    ///
    /// Keyed on that observable state — not on whether *this* call is the one
    /// that created a given sibling — so it reconciles regardless of which
    /// attempt, or which launch, is responsible: this call's own set-aside
    /// directory when it wins the rename outright, this call's own directory when
    /// it instead loses the race after already setting one aside, and a sibling
    /// orphaned by an entirely earlier, failed launch that this call never
    /// touched at all. Called from every path in `migrate` and
    /// `attemptMigration` that ends with `new` holding a store: the success path,
    /// the lost-the-race branch, and the fresh-install guard (which also covers
    /// "already migrated, however long ago").
    ///
    /// Best-effort throughout: nothing here throws, because by the time this
    /// runs the migration itself already succeeded (or had already succeeded on
    /// some earlier launch) and reporting `.failed` for a leftover crumb that
    /// didn't make it back would be wrong. Whatever doesn't merge — a genuine
    /// name collision, most plausibly, since anything in a set-aside sibling was
    /// at most helper-created before its rename ran — stays in that sibling,
    /// which is left on disk rather than deleted, for someone to look at by hand.
    private static func reconcileSetAsideSiblings(
        sharedApplicationSupport: URL, newBundleIdentifier: String, fileManager: FileManager
    ) {
        let new = sharedApplicationSupport.appending(path: newBundleIdentifier, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: new.appending(path: AudioStorage.storeFileName).path) else { return }
        guard let siblings = try? fileManager.contentsOfDirectory(atPath: sharedApplicationSupport.path) else {
            return
        }

        let prefix = "\(newBundleIdentifier).pre-migration-"
        for name in siblings where name.hasPrefix(prefix) {
            mergeSetAsideRemnants(
                sharedApplicationSupport.appending(path: name, directoryHint: .isDirectory), into: new,
                fileManager: fileManager
            )
        }
    }

    /// Merges one set-aside directory's contents into `new`, never overwriting a
    /// name that's already there, and removes the set-aside directory only once
    /// it's been fully emptied — a colliding item left behind is exactly what
    /// keeps it non-empty and un-removed until whatever collided with it is
    /// resolved by hand.
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
