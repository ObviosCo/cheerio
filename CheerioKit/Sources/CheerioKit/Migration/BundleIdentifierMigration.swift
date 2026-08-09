import Darwin
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
/// this rename can. Two Cheerio processes racing this exact migration are
/// serialized by an inter-process file lock rather than handled as one-off
/// interleavings — see ``withMigrationLock(sharedApplicationSupport:newBundleIdentifier:_:)``
/// — with a retry loop and a stranded-store safety net kept as belt-and-braces
/// underneath it.
public enum BundleIdentifierMigration {
    private static let log = Logger(subsystem: AudioStorage.appBundleIdentifier, category: "BundleIdentifierMigration")

    /// How many times ``migrate(sharedApplicationSupport:oldBundleIdentifier:newBundleIdentifier:fileManager:)``
    /// re-reads the world and retries after a move throws, before concluding the
    /// failure is real rather than another launch racing the same migration.
    /// Small on purpose: with the inter-process lock below, this exists only to
    /// absorb the tail of a race that started before the lock was acquired or the
    /// rare case the lock itself couldn't be taken (see
    /// ``withMigrationLock(sharedApplicationSupport:newBundleIdentifier:_:)``), not
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
        /// whether this call performed the rename itself, lost the race to another
        /// launch that did, or had to recover the real container from a sibling it
        /// had been displaced into.
        case migrated
        /// Both containers hold a SwiftData store already. Neither is touched: the
        /// new one holds data written since the identifier changed (a second
        /// migrated launch, concurrently or since, or a real second history), and
        /// the old one is not this migration's to discard. The caller opens the new
        /// container, as it always does.
        case bothExist
        /// Every retry was exhausted without the world ever settling into a
        /// recognized shape, and no set-aside sibling was found holding the real
        /// store either — a genuine, repeatable I/O error (permissions, most
        /// plausibly) throwing the same way on every attempt, since a transient
        /// race with another launch resolves within a couple of retries instead,
        /// and a displaced store would have been recovered before this is ever
        /// returned (see ``migrate(sharedApplicationSupport:oldBundleIdentifier:newBundleIdentifier:fileManager:)``).
        /// `old` has not been touched in every path that reaches this: nothing is
        /// ever taken out of it until the rename that makes `new` current, which is
        /// one atomic step, so a failure setting a pre-existing store-less `new`
        /// aside or performing that rename always leaves `old` exactly as it was.
        /// The caller can safely keep operating against the *old* identifier for
        /// this launch (see ``AudioStorage/setContainerOverride(_:)``) rather than
        /// open an empty or partially-set-up new container and present that as the
        /// library. The next launch simply retries the whole thing from scratch.
        case failed
        /// A `pre-migration-*` sibling was found holding the real store, but
        /// restoring it to `new` itself failed (see
        /// ``restoreStrandedStore(outcome:sharedApplicationSupport:new:newBundleIdentifier:fileManager:)``)
        /// — recovering the *directory* isn't possible on this launch, but the
        /// store's *location* is known, so this is neither `.freshInstall` nor
        /// `.failed`: both of those would have the caller open or create an empty
        /// container while a real store sits one directory over — `.freshInstall`
        /// by letting `AudioStorage.applicationSupport()` create a blank `new`,
        /// `.failed` by falling back to `old`, which may not even exist any more
        /// (this shape is exactly what "another attempt's full migration already
        /// completed" produces). The associated value is the sibling's directory
        /// *name* — not a full `URL` — because that's what
        /// ``AudioStorage/setContainerOverride(_:)`` already takes: a path
        /// component resolved against the shared Application Support parent, the
        /// same as a bundle identifier would be. The caller sets the override to
        /// this name so the launch opens the real store where it actually is,
        /// rather than trying to relocate it first; the next launch's own
        /// stranded-store safety net gets another chance to restore the directory
        /// itself.
        case storeStrandedInSibling(directoryName: String)
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
    /// The whole thing runs inside ``withMigrationLock(sharedApplicationSupport:newBundleIdentifier:_:)``,
    /// which is the primary defense against two Cheerio processes racing this
    /// exact migration: a concurrent launch simply blocks for the few
    /// milliseconds this takes, so the set-aside/rename dance above never
    /// actually interleaves with another attempt at it in production. What's
    /// below this point is belt-and-braces underneath that, not the primary
    /// mechanism, kept because the lock is a courtesy (see that function) rather
    /// than a hard requirement, and because proving the fallback machinery works
    /// on its own is cheaper than trusting it never has to:
    ///
    /// - A move throwing inside ``attemptMigration(sharedApplicationSupport:old:new:newStore:oldBundleIdentifier:newBundleIdentifier:fileManager:)``
    ///   just asks for a retry rather than deciding on the spot — the next
    ///   attempt re-reads `old` and `newStore` from scratch and resolves to
    ///   `.migrated` on its own if that shows another attempt already finished.
    /// - ``reconcileSetAsideSiblings(sharedApplicationSupport:newBundleIdentifier:fileManager:)``
    ///   folds a set-aside sibling's contents back into `new` once `new` holds a
    ///   store, keyed on that observable state rather than on which attempt or
    ///   launch created a given sibling.
    /// - ``restoreStrandedStore(outcome:sharedApplicationSupport:new:newBundleIdentifier:fileManager:)``
    ///   is the last line: if `new` ends up without a store but a sibling holds
    ///   one — the shape produced when an attempt observes a bare `new`, but
    ///   another attempt's *entire* migration completes before the first one
    ///   gets around to actually moving what it saw, so it ends up moving the
    ///   second attempt's freshly-migrated real container into its own sibling
    ///   by mistake — that sibling is restored to `new` before `migrate` returns
    ///   any outcome, turning what the retry loop alone would report as
    ///   `.failed` into `.migrated` instead. If the restore *itself* then fails
    ///   (an I/O error moving a directory that's sitting right there — rare, but
    ///   not impossible), the result is `.storeStrandedInSibling(directoryName:)`
    ///   rather than silently falling back to `.freshInstall` or `.failed`: both
    ///   of those would have the caller open or create an empty container while
    ///   the real store sits one directory over, which is precisely the failure
    ///   mode every mechanism above exists to rule out.
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

        return withMigrationLock(sharedApplicationSupport: sharedApplicationSupport, newBundleIdentifier: newBundleIdentifier) {
            let outcome = resolveMigration(
                sharedApplicationSupport: sharedApplicationSupport, old: old, new: new, newStore: newStore,
                oldBundleIdentifier: oldBundleIdentifier, newBundleIdentifier: newBundleIdentifier,
                fileManager: fileManager
            )
            return restoreStrandedStore(
                outcome: outcome, sharedApplicationSupport: sharedApplicationSupport, new: new,
                newBundleIdentifier: newBundleIdentifier, fileManager: fileManager
            )
        }
    }

    /// The decision `migrate` makes while holding the lock: fresh-install and
    /// both-exist are one-time checks against the state `migrate` started with,
    /// and everything past them retries against whatever the world looks like on
    /// each attempt.
    private static func resolveMigration(
        sharedApplicationSupport: URL, old: URL, new: URL, newStore: URL,
        oldBundleIdentifier: String, newBundleIdentifier: String, fileManager: FileManager
    ) -> Outcome {
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
    /// ask ``resolveMigration(sharedApplicationSupport:old:new:newStore:oldBundleIdentifier:newBundleIdentifier:fileManager:)``
    /// for another attempt: a thrown move here doesn't yet distinguish a genuine,
    /// repeatable failure from another attempt having reached the same fork
    /// first, and re-reading state at the top of the *next* attempt is what
    /// tells them apart, not anything available at the point of the throw
    /// itself.
    private static func attemptMigration(
        sharedApplicationSupport: URL, old: URL, new: URL, newStore: URL,
        oldBundleIdentifier: String, newBundleIdentifier: String, fileManager: FileManager
    ) -> Outcome? {
        guard fileManager.fileExists(atPath: old.path) else {
            guard fileManager.fileExists(atPath: newStore.path) else {
                // `old` disappeared without `new` ever holding a store — not a
                // shape any attempt racing this same migration produces on its
                // own, and retrying can't bring `old` back. This is exactly the
                // shape a mis-set-aside also produces (this attempt itself moved
                // a just-migrated `new` into one of its own siblings by
                // mistake), which is why `.failed` here isn't necessarily final —
                // ``restoreStrandedStore(outcome:sharedApplicationSupport:new:newBundleIdentifier:fileManager:)``
                // gets a chance to look for exactly that before `migrate` returns.
                return .failed
            }
            log.notice(
                "Lost the migration race to another attempt; \(newBundleIdentifier, privacy: .public) is already the current container."
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
            // failure (permissions, most plausibly), or another attempt reaching
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

    /// Runs `body` while holding an exclusive inter-process lock on a file next
    /// to `old`/`new` themselves, so two Cheerio processes racing this exact
    /// migration serialize instead of interleaving. This is the primary defense
    /// — the retry loop and the reconcile/restore machinery elsewhere in this
    /// type exist to absorb what's left over *around* the lock (a race that
    /// started before it was acquired, or the lock itself not being available),
    /// not to substitute for it: without this, two launches racing the set-aside
    /// step, one launch's set-aside racing another's rename, or one launch
    /// displacing a container another just finished migrating are all real,
    /// separately-reachable interleavings, each needing its own reasoning to
    /// rule out. With it, a concurrent launch simply blocks for the few
    /// milliseconds the whole migration takes, and none of those interleavings
    /// can occur *by construction* — there is nothing left running concurrently
    /// for them to interleave with.
    ///
    /// `flock(2)`, not `NSFileCoordinator`: this only needs to keep cooperating
    /// copies of the very same app from interleaving on the very same
    /// directory, which is exactly what an advisory inter-process file lock is
    /// for, and simpler than standing up a coordinator for it. The lock is
    /// released the instant this process's file descriptor for it closes — on
    /// the `defer` below in the ordinary case, but also, at the kernel level, on
    /// the process exiting for *any* reason, crash included. That means there is
    /// no stale-lock state to detect or clean up: a holder that dies mid-
    /// migration releases the lock as a side effect of dying, and the next
    /// launch acquires it fresh rather than finding a lock file it has to
    /// reason about the age or ownership of.
    ///
    /// Best-effort rather than a hard requirement: if the lock file can't even
    /// be opened (a read-only Application Support, most plausibly, though
    /// nothing in normal operation makes that true) — or, per below, if
    /// acquiring it fails for a reason that isn't just a signal interrupting
    /// the wait — this runs `body` unlocked rather than refusing to migrate at
    /// all. The retry loop and the stranded-store restore are what keep that
    /// degraded path safe too — this function's contract is "serialize when
    /// possible," not "never run without serializing." Both fallbacks are
    /// logged explicitly: silently proceeding unlocked, having assumed
    /// serialization succeeded, would be worse than the thing this function
    /// exists to prevent.
    ///
    /// `flock`'s return value is checked, not assumed: a blocking call can
    /// still return `-1` — most plausibly `EINTR`, a signal interrupting the
    /// wait, which says nothing about whether the lock is actually available
    /// and is retried in the loop below rather than treated as a failure. Any
    /// *other* errno is a real inability to acquire the lock, and only then
    /// does this fall back to running unlocked; the unlock is registered only
    /// once the loop's exit condition confirms the lock was actually taken, so
    /// a `flock(LOCK_UN)` never fires against a descriptor that was never
    /// locked in the first place.
    private static func withMigrationLock<T>(
        sharedApplicationSupport: URL, newBundleIdentifier: String, _ body: () -> T
    ) -> T {
        let lockURL = sharedApplicationSupport.appending(path: "\(newBundleIdentifier).migration.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            log.error(
                "Couldn't open the migration lock file at \(lockURL.path, privacy: .public) (errno \(errno, privacy: .public)); running this migration unserialized."
            )
            return body()
        }
        defer { close(descriptor) }

        var result: Int32
        var acquireErrno: Int32 = 0
        repeat {
            result = flock(descriptor, LOCK_EX)
            acquireErrno = errno
        } while result == -1 && acquireErrno == EINTR

        guard result == 0 else {
            log.error(
                "Couldn't acquire the migration lock (errno \(acquireErrno, privacy: .public)); running this migration unserialized."
            )
            return body()
        }
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    /// The last line of defense: if `new` doesn't hold a store but a
    /// `<newBundleIdentifier>.pre-migration-*` sibling does, that sibling *is*
    /// the real container, displaced by whatever interleaving produced this —
    /// nothing but this migration's own set-aside step ever creates a directory
    /// holding ``AudioStorage/storeFileName`` under that naming convention, which
    /// is what makes finding one there an identity check, not a guess. It's
    /// restored to `new` before `migrate` returns, regardless of which `outcome`
    /// the rest of the decision computed, and regardless of whether the lock
    /// above actually prevented every interleaving it's meant to: this doesn't
    /// depend on *why* the store ended up in a sibling, only on the fact that it
    /// did. Concretely, this is what recovers the shape one attempt observing a
    /// bare `new` while a second attempt's entire migration completes before the
    /// first gets around to moving what it saw produces: the first attempt ends
    /// up moving the second attempt's freshly-migrated real container into its
    /// own sibling by mistake, its own rename of the now-gone `old` throws, and
    /// the retry loop's fresh read sees `old` gone and `new` storeless — a shape
    /// nothing else recognizes — and reports `.failed` while the real store sits
    /// exactly one directory away.
    ///
    /// Runs inside the same lock `migrate` already holds, so this doesn't
    /// introduce a *new* race between two concurrent restores; it's independent
    /// of the lock only in the sense that it doesn't assume the interleaving it
    /// exists to catch was actually prevented.
    ///
    /// Transactional in the one way that matters here: landing the sibling at
    /// `new` is two moves (displacing whatever's currently at `new`, then
    /// moving the sibling in), and if the second one fails after the first
    /// succeeded, this rolls the first back rather than returning with `new`
    /// simply absent and the real store still sitting, untouched, in its
    /// sibling — the exact stranding this function exists to fix, just
    /// relocated one directory over. `sibling` itself is never touched until
    /// the second move, so a failure there always leaves it exactly as this
    /// function found it, for a retried call (or the next launch) to try
    /// again.
    ///
    /// Once a store-bearing sibling has been found, this never falls back to
    /// the `outcome` it was handed: every remaining exit reports
    /// ``Outcome/storeStrandedInSibling(directoryName:)`` instead. `outcome`
    /// itself is only ever returned before that point — no qualifying sibling
    /// exists, or the sibling listing couldn't be read at all — which is the
    /// one case where falling back to whatever `resolveMigration` already
    /// decided is actually correct, because nothing here found anything to
    /// contradict it.
    private static func restoreStrandedStore(
        outcome: Outcome, sharedApplicationSupport: URL, new: URL, newBundleIdentifier: String,
        fileManager: FileManager
    ) -> Outcome {
        guard !fileManager.fileExists(atPath: new.appending(path: AudioStorage.storeFileName).path) else {
            return outcome
        }
        guard let siblings = try? fileManager.contentsOfDirectory(atPath: sharedApplicationSupport.path) else {
            return outcome
        }

        let prefix = "\(newBundleIdentifier).pre-migration-"
        for name in siblings where name.hasPrefix(prefix) {
            let sibling = sharedApplicationSupport.appending(path: name, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: sibling.appending(path: AudioStorage.storeFileName).path) else {
                continue
            }

            // Whatever currently occupies `new` has no store of its own (the
            // guard above already established that), so it's displaced rather
            // than overwritten blindly — the next reconcile pass folds it back
            // in if nothing collides. A failure here hasn't touched `sibling`
            // or moved anything into `new`, so nothing needs rolling back:
            // both are exactly as this function found them.
            var displaced: URL?
            if fileManager.fileExists(atPath: new.path) {
                let destination = sharedApplicationSupport.appending(
                    path: "\(newBundleIdentifier).pre-migration-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
                do {
                    try fileManager.moveItem(at: new, to: destination)
                    displaced = destination
                } catch {
                    log.error(
                        "Found a stranded store at \(sibling.path, privacy: .public) but couldn't clear \(new.path, privacy: .public) to restore it: \(error). Pointing this launch at the sibling directly."
                    )
                    return .storeStrandedInSibling(directoryName: name)
                }
            }

            do {
                try fileManager.moveItem(at: sibling, to: new)
            } catch {
                // The first move succeeded but this one didn't: `new` is
                // provably clear but doesn't have the real store either. Roll
                // `displaced` back into `new` so this attempt leaves nothing
                // worse than it found — `sibling` was never touched by this
                // branch, so it's untouched regardless of whether the rollback
                // below succeeds.
                if let displaced {
                    do {
                        try fileManager.moveItem(at: displaced, to: new)
                    } catch {
                        // Both halves failed. `sibling` is still intact and
                        // untouched — that's what actually matters, since it's
                        // what the next attempt's own copy of this same check
                        // will look for and find, whether that's a retry of
                        // this call or the next launch entirely — but `new`
                        // may now be in neither its original nor its restored
                        // state, so this is logged loudly rather than folded
                        // into the quieter message below. Either way, this
                        // launch still knows exactly where the real store is.
                        log.error(
                            "Couldn't restore the stranded store at \(sibling.path, privacy: .public), and couldn't roll back \(displaced.path, privacy: .public) to \(new.path, privacy: .public) either: \(error). The real store remains intact at \(sibling.path, privacy: .public); pointing this launch there directly."
                        )
                        return .storeStrandedInSibling(directoryName: name)
                    }
                }
                log.error(
                    "Found a stranded store at \(sibling.path, privacy: .public) but couldn't restore it: \(error). Pointing this launch at the sibling directly."
                )
                return .storeStrandedInSibling(directoryName: name)
            }

            log.notice(
                "Restored the migrated container from \(sibling.path, privacy: .public), which had displaced it."
            )
            reconcileSetAsideSiblings(
                sharedApplicationSupport: sharedApplicationSupport, newBundleIdentifier: newBundleIdentifier,
                fileManager: fileManager
            )
            return .migrated
        }
        return outcome
    }

    /// Sweeps every `<newBundleIdentifier>.pre-migration-*` sibling of `new` and
    /// folds whatever in each one doesn't collide back into `new`, once `new`
    /// actually holds a store.
    ///
    /// Keyed on that observable state — not on whether *this* call is the one
    /// that created a given sibling — so it reconciles regardless of which
    /// attempt is responsible: this call's own set-aside directory when it wins
    /// the rename outright, this call's own directory when it instead loses the
    /// race after already setting one aside, and a sibling orphaned by an
    /// entirely earlier, failed attempt that this call never touched at all.
    /// Called from every path in `resolveMigration`, `attemptMigration`, and
    /// `restoreStrandedStore` that ends with `new` holding a store: the success
    /// path, the lost-the-race branch, the fresh-install guard (which also
    /// covers "already migrated, however long ago"), and after a stranded-store
    /// restore.
    ///
    /// Best-effort throughout: nothing here throws, because by the time this
    /// runs the migration itself already succeeded (or had already succeeded on
    /// some earlier attempt) and reporting `.failed` for a leftover crumb that
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
