import Foundation
import Testing

@testable import CheerioKit

/// Exercises ``BundleIdentifierMigration`` against a scratch directory standing in
/// for `~/Library/Application Support` — never the real one, and never touching
/// `AudioStorage`'s real identifiers, so a run of this suite can't collide with
/// anything a developer actually has on disk.
@Suite struct BundleIdentifierMigrationTests {
    private let oldID = "old.bundle.id"
    private let newID = "new.bundle.id"

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bundle-id-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func freshInstallHasNothingToMove() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID
        )

        #expect(outcome == .freshInstall)
        #expect(!FileManager.default.fileExists(atPath: shared.appending(path: newID).path))
    }

    @Test func upgradeMovesTheWholeOldContainer() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        let oldMeetingDirectory = old.appending(path: "Meetings/abc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: oldMeetingDirectory, withIntermediateDirectories: true)
        try Data("store".utf8).write(to: old.appending(path: "default.store"))

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID
        )

        #expect(outcome == .migrated)
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "default.store").path))
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "Meetings/abc").path))
    }

    /// A machine that already migrated on an earlier launch, and has since had the
    /// (now-empty, or fully-removed) old directory disappear entirely, looks
    /// identical to a fresh install from this function's point of view — there is
    /// nothing left on disk to tell the two apart by, and both get the same correct
    /// answer: do nothing, the new container already holds everything.
    @Test func alreadyMigratedIsANoOpJustLikeFreshInstall() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("already-migrated".utf8).write(to: new.appending(path: "default.store"))

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID
        )

        #expect(outcome == .freshInstall)
        #expect(
            try Data(contentsOf: new.appending(path: "default.store")) == Data("already-migrated".utf8)
        )
    }

    /// Every sibling of `new` this suite's scenarios can leave behind on purpose —
    /// the set-aside directory a store-less `new` gets moved to before the rename —
    /// carries this prefix, so a test can assert none (or exactly one) exists
    /// without hardcoding the UUID `migrate` mints for it.
    private func setAsideSiblings(of shared: URL, newBundleIdentifier: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: shared, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(newBundleIdentifier).pre-migration-") }
    }

    /// The production incident (#126): an MCP client resolved the helper's store
    /// path — creating nothing but a bare parent directory along the way, in the
    /// version of the helper running that morning — before the rebuilt app had ever
    /// launched to migrate anything. The old guard read that empty directory as
    /// "already migrated" and walked away, stranding the whole library under the
    /// old identifier. The fix: a new directory with no store in it is moved aside
    /// so the old container can still land at `new` by a single atomic rename, same
    /// as if the bare directory had never existed.
    @Test func bareNewDirectoryMigratesTheOldContentsIn() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        let oldMeetingDirectory = old.appending(path: "Meetings/abc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: oldMeetingDirectory, withIntermediateDirectories: true)
        try Data("store".utf8).write(to: old.appending(path: "default.store"))
        // Bare: exists, empty, no store — exactly what a path resolution that only
        // ever reads (never writes) can still leave behind as a side effect of
        // resolving `.applicationSupportDirectory` itself.
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID
        )

        #expect(outcome == .migrated)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "default.store").path))
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "Meetings/abc").path))
        // Nothing was ever in the bare directory this set aside, so the set-aside
        // sibling itself is empty afterward and gets cleaned up rather than left
        // behind as permanent clutter next to every fresh migration.
        #expect(try setAsideSiblings(of: shared, newBundleIdentifier: newID).isEmpty)
    }

    /// A new directory that exists for a reason with nothing to do with migration —
    /// here standing in for a stray file dropped by something else entirely — must
    /// keep that file exactly as it was. It doesn't collide with anything `old`
    /// owns, so it's merged straight back into the now-migrated `new` once the
    /// rename lands, rather than staying quarantined in the set-aside directory.
    @Test func newDirectoryWithUnrelatedFileButNoStoreMigratesWithoutClobberingIt() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("store".utf8).write(to: old.appending(path: "default.store"))
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: new.appending(path: "widget.json"))

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID
        )

        #expect(outcome == .migrated)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "default.store").path))
        // Preserved by ending up merged back into `new`, not by having been left
        // untouched in place — `new`'s original directory was moved aside and a
        // fresh one took its place via the rename from `old`.
        #expect(try Data(contentsOf: new.appending(path: "widget.json")) == Data("unrelated".utf8))
        #expect(try setAsideSiblings(of: shared, newBundleIdentifier: newID).isEmpty)
    }

    /// The active review finding this exists to close: a destination-name
    /// collision must never be silently skipped while still reporting
    /// `.migrated` — that would leave `default.store` moved to `new` with its own
    /// `Meetings` folder still behind it in whatever the colliding item swallowed,
    /// making those recordings unreachable through the container that's now
    /// current. Setting `new` aside wholesale before the rename means the
    /// collision is discovered *after* `old`'s entire tree — `Meetings` included —
    /// is already sitting at `new`; only the leftover crumb from the old `new` is
    /// at risk of not making it back, and it's quarantined, not dropped.
    @Test func newDirectoryWithACollidingSubdirectoryIsQuarantinedNotDropped() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: old.appending(path: "Meetings/abc", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("store".utf8).write(to: old.appending(path: "default.store"))
        // A `Meetings` directory of its own, colliding by name with `old`'s —
        // exactly the shape Copilot's review flagged as silently stranding data.
        try FileManager.default.createDirectory(
            at: new.appending(path: "Meetings", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("stray".utf8).write(to: new.appending(path: "Meetings/xyz.caf"))

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID
        )

        #expect(outcome == .migrated)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        // The whole point: `old`'s own `Meetings` tree is reachable at `new`
        // regardless of what the colliding directory held — nothing from `old`
        // was ever at risk, because the collision was resolved before the rename
        // touched `old` at all, not by picking a winner between the two trees.
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "default.store").path))
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "Meetings/abc").path))
        // The stray file that collided is neither silently gone nor clobbering
        // what `old` owned — it's quarantined in the set-aside sibling.
        #expect(!FileManager.default.fileExists(atPath: new.appending(path: "Meetings/xyz.caf").path))
        let siblings = try setAsideSiblings(of: shared, newBundleIdentifier: newID)
        #expect(siblings.count == 1)
        let sibling = try #require(siblings.first)
        #expect(
            try Data(contentsOf: sibling.appending(path: "Meetings/xyz.caf")) == Data("stray".utf8)
        )
    }

    /// The suppressed review finding this exists to close: an item-by-item merge
    /// makes a partial failure indistinguishable from "safe to fall back to the
    /// old identifier," because some of `old`'s items — possibly `default.store`
    /// itself, since directory-enumeration order isn't guaranteed — could already
    /// be gone from `old` by the time the error surfaces. Reclaiming atomicity
    /// closes that: nothing is ever taken out of `old` until the rename step,
    /// which is one atomic `moveItem`, so a failure setting `new` aside can only
    /// ever happen *before* `old` is touched.
    @Test func settingAsideFailureLeavesBothContainersUntouched() throws {
        guard getuid() != 0 else { return }

        let shared = try scratchDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path)
            try? FileManager.default.removeItem(at: shared)
        }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old-data".utf8).write(to: old.appending(path: "default.store"))
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)

        // A read-only parent can't have an entry removed from or added to it,
        // which blocks the set-aside move (an entry leaving `new`'s parent) before
        // the rename of `old` is ever attempted.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: shared.path)

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID
        )

        #expect(outcome == .failed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path)
        #expect(try Data(contentsOf: old.appending(path: "default.store")) == Data("old-data".utf8))
        #expect(!FileManager.default.fileExists(atPath: new.appending(path: "default.store").path))
    }

    /// The other half of the same property: a failure on the rename itself, after
    /// the set-aside step already succeeded, must still leave `old` exactly as it
    /// was — not partially emptied by however far an item-by-item merge would
    /// have gotten. `old` here is asserted intact by content, not just by
    /// existence, since a corrupted-but-present `default.store` would pass a bare
    /// `fileExists` check and still be exactly the split-brain state this design
    /// exists to rule out.
    @Test func renameFailureAfterSettingAsideLeavesOldCompletelyIntact() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: old.appending(path: "Meetings/abc", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("old-data".utf8).write(to: old.appending(path: "default.store"))
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID,
            fileManager: FailsOnTheSecondMoveFileManager()
        )

        #expect(outcome == .failed)
        #expect(try Data(contentsOf: old.appending(path: "default.store")) == Data("old-data".utf8))
        #expect(FileManager.default.fileExists(atPath: old.appending(path: "Meetings/abc").path))
        // `new`'s original bare directory was already relocated by the (successful)
        // set-aside step; nothing else ever landed at `new` itself.
        #expect(!FileManager.default.fileExists(atPath: new.appending(path: "default.store").path))
    }

    @Test func bothExistingNeverClobbersEither() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("old-data".utf8).write(to: old.appending(path: "default.store"))
        try Data("new-data".utf8).write(to: new.appending(path: "default.store"))

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID
        )

        #expect(outcome == .bothExist)
        #expect(try Data(contentsOf: new.appending(path: "default.store")) == Data("new-data".utf8))
        #expect(try Data(contentsOf: old.appending(path: "default.store")) == Data("old-data".utf8))
    }

    /// Simulates a move failure (the old directory exists but can't be renamed) by
    /// pointing at an old "directory" that is actually a file — `moveItem` on that
    /// still succeeds on most filesystems, so instead this locks the *parent* down
    /// to provoke a real permissions failure, and restores it in `defer` regardless
    /// of outcome so a failing assertion can't leave a read-only scratch directory
    /// behind.
    @Test func moveFailureLeavesTheOldDirectoryInPlace() throws {
        // Root ignores POSIX permission bits entirely, so the provoked failure below
        // would silently succeed instead — nothing left to assert on a CI runner that
        // happens to execute tests as root.
        guard getuid() != 0 else { return }

        let shared = try scratchDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path)
            try? FileManager.default.removeItem(at: shared)
        }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old-data".utf8).write(to: old.appending(path: "default.store"))

        // A read-only parent directory can't have an entry removed from it, which is
        // exactly what a rename does to its source's parent.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: shared.path)

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID
        )

        #expect(outcome == .failed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path)
        #expect(FileManager.default.fileExists(atPath: old.appending(path: "default.store").path))
        #expect(!FileManager.default.fileExists(atPath: shared.appending(path: newID).path))
    }

    /// Reproduces the interleaving directly, rather than faking the error it
    /// produces: nothing prevents a second Cheerio process from launching at the
    /// same moment, and if *that* process's `moveItem` wins the identical rename
    /// between this call's existence checks and its own `moveItem`, our call sees
    /// the source vanish out from under it. The fix is in `migrate`'s `catch`
    /// block, not in this test — this only proves the fix handles a real race
    /// instead of the narrower "moveItem threw for some reason" case.
    @Test func losingTheRaceToAConcurrentLaunchStillReportsSuccess() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("migrated-by-the-other-launch".utf8).write(to: old.appending(path: "default.store"))

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID,
            fileManager: RaceSimulatingFileManager()
        )

        #expect(outcome == .migrated)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(
            try Data(contentsOf: new.appending(path: "default.store"))
                == Data("migrated-by-the-other-launch".utf8)
        )
    }

    /// The active review finding: two launches can both observe a store-less
    /// `new` and both try to move it aside. Forcing `new` to be bare (rather than
    /// absent) routes this launch through the set-aside branch first, which is
    /// exactly where the interleaving happens — `RaceSimulatingFileManager`
    /// reproduces a second launch winning that identical move, then (since `new`
    /// no longer exists to move a second time) winning the identical old→new
    /// rename too. Both throws ask for a retry rather than reporting `.failed`;
    /// the third attempt's fresh read finds `old` gone and `new` holding a store
    /// and recognizes the race as already won, within `maxMigrationAttempts`.
    @Test func aSetAsideRaceAsksForARetryInsteadOfFailing() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: old.appending(path: "Meetings/abc", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("migrated-by-the-other-launch".utf8).write(to: old.appending(path: "default.store"))
        // Bare and store-less — forces the set-aside branch, unlike
        // `losingTheRaceToAConcurrentLaunchStillReportsSuccess` above, where `new`
        // is absent and the race is only on the rename itself.
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID,
            fileManager: RaceSimulatingFileManager()
        )

        #expect(outcome == .migrated)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(
            try Data(contentsOf: new.appending(path: "default.store"))
                == Data("migrated-by-the-other-launch".utf8)
        )
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "Meetings/abc").path))
        // The bare directory this launch's own (raced-away) set-aside attempt
        // touched doesn't linger as an unreconciled sibling once the dust settles.
        #expect(try setAsideSiblings(of: shared, newBundleIdentifier: newID).isEmpty)
    }

    /// The first suppressed review finding: losing the actual old→new rename
    /// race after this launch's *own* set-aside step already succeeded must
    /// still reconcile the sibling that step created — the early return for
    /// "another launch already finished" can't just skip it, or a file that was
    /// legitimately in `new` before this migration ever started stays stranded
    /// in a UUID directory nobody ever named again, even though the migration as
    /// a whole reports success.
    @Test func losingTheRenameRaceStillReconcilesThisLaunchsOwnSibling() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: old.appending(path: "Meetings/abc", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("store".utf8).write(to: old.appending(path: "default.store"))
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("crumb".utf8).write(to: new.appending(path: "widget.json"))

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID,
            fileManager: LosesTheRenameRaceAfterSettingAsideFileManager()
        )

        #expect(outcome == .migrated)
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "default.store").path))
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "Meetings/abc").path))
        // The file that was in `new` before this launch ever touched it made it
        // back, even though a different launch's rename is the one that actually
        // won — reconciliation ran on this launch's own set-aside sibling anyway.
        #expect(try Data(contentsOf: new.appending(path: "widget.json")) == Data("crumb".utf8))
        #expect(try setAsideSiblings(of: shared, newBundleIdentifier: newID).isEmpty)
    }

    /// The second suppressed review finding: a sibling orphaned by a *previous*
    /// launch's set-aside-then-genuinely-failed attempt is never revisited by
    /// the ordinary machinery — the next successful launch finds `new` simply
    /// absent (the orphan sits under a UUID-suffixed name, not `new`'s own) and
    /// takes the plain-rename fast path with nothing pointing it at the orphan.
    /// Reconciliation being keyed on "`new` now holds a store," rather than on
    /// which attempt or launch created a given sibling, is what still sweeps it.
    @Test func orphanedSiblingFromAnEarlierFailedLaunchIsSweptByALaterOne() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: old.appending(path: "Meetings/abc", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("store".utf8).write(to: old.appending(path: "default.store"))
        // Stands in for an earlier launch that moved a store-less `new` aside and
        // then genuinely failed the rename: `new` itself is simply absent, and
        // nothing but this sibling's own name still points back at what it was.
        let orphan = shared.appending(
            path: "\(newID).pre-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("crumb".utf8).write(to: orphan.appending(path: "widget.json"))

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID
        )

        #expect(outcome == .migrated)
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "default.store").path))
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "Meetings/abc").path))
        #expect(try Data(contentsOf: new.appending(path: "widget.json")) == Data("crumb".utf8))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    /// The active review finding on the previous round's retry fix: the retry
    /// loop's fresh read can be fooled by *this* attempt's own actions, not just
    /// another attempt's. If a second attempt's entire migration completes in
    /// the exact gap between this attempt observing a bare `new` and this
    /// attempt's own move to set it aside, this attempt ends up moving the
    /// *other attempt's freshly-migrated real container* into its own sibling —
    /// its `old` is gone by then (the other attempt took it), so its own rename
    /// throws, and on retry it sees `old` gone and `new` storeless (this
    /// attempt itself just emptied it, by mistake) with no shape the retry loop
    /// recognizes, reporting `.failed` while the real store sits one directory
    /// away. Only the stranded-store safety net, not the retry loop, closes
    /// this — this test simulates the interleaving purely at the `FileManager`
    /// layer, standing in for the per-process lock having somehow been
    /// bypassed, to prove the safety net recovers on its own regardless.
    @Test func strandedStoreIsRestoredEvenWhenAnotherAttemptsFullMigrationInterleaves() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let old = shared.appending(path: oldID, directoryHint: .isDirectory)
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: old.appending(path: "Meetings/abc", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("real-store".utf8).write(to: old.appending(path: "default.store"))
        // Bare and store-less: what this attempt observes, right before the
        // interleaved "other attempt" replaces it with the real container.
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let otherAttemptsSibling = shared.appending(
            path: "\(newID).pre-migration-other-attempt", directoryHint: .isDirectory)

        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID,
            fileManager: InterleavesAnotherAttemptsCompleteMigrationFileManager(
                old: old, new: new, otherAttemptsSibling: otherAttemptsSibling
            )
        )

        #expect(outcome == .migrated)
        #expect(try Data(contentsOf: new.appending(path: "default.store")) == Data("real-store".utf8))
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "Meetings/abc").path))
        // Nothing left stranded: this attempt's own (misdirected) sibling was
        // the one restored, and the other attempt's now-empty leftover was
        // swept as part of the same reconcile pass that follows a restore.
        #expect(try setAsideSiblings(of: shared, newBundleIdentifier: newID).isEmpty)
    }

    /// Two review findings on the restore itself, both closed here. Landing a
    /// stranded store at `new` is two moves — displacing whatever's currently
    /// there, then moving the sibling in — and if the second one fails after
    /// the first succeeded, this must not return with `new` simply absent and
    /// the real store still sitting, untouched, in its sibling. That's the
    /// exact stranding the restore exists to fix, just relocated one
    /// directory over, so the displaced directory is rolled back into `new`.
    /// But rolling `new` back to what it was — a store-less directory that
    /// was never a real library to begin with — and then reporting whatever
    /// ordinary outcome `resolveMigration` had already decided (`.freshInstall`
    /// here) would reproduce the *exact same* stranding one level up: the
    /// caller would open or create an empty container while the real store
    /// sits, known and findable, one directory away. So this reports
    /// `.storeStrandedInSibling(directoryName:)` instead, regardless of
    /// whether the rollback itself succeeded — it's the second move (the one
    /// that would have actually landed the real store) failing that decides
    /// this, not what happened to the temporary displacement.
    @Test func failingToLandTheStrandedStoreRollsBackAndReportsWhereItActuallyIs() throws {
        let shared = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: shared) }
        let new = shared.appending(path: newID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("crumb".utf8).write(to: new.appending(path: "widget.json"))
        let sibling = shared.appending(
            path: "\(newID).pre-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: sibling.appending(path: "Meetings/abc", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("real-store".utf8).write(to: sibling.appending(path: "default.store"))

        // `old` is never created — this test is entirely about the restore's
        // own behavior, not about how a store ended up in a sibling in the
        // first place.
        let outcome = BundleIdentifierMigration.migrate(
            sharedApplicationSupport: shared, oldBundleIdentifier: oldID, newBundleIdentifier: newID,
            fileManager: FailsRestoringTheStrandedStoreFileManager()
        )

        #expect(outcome == .storeStrandedInSibling(directoryName: sibling.lastPathComponent))
        // `new` is back exactly where this attempt found it: bare, its own
        // crumb intact, no store — but that's not what the *outcome* reports,
        // precisely because it isn't a real library.
        #expect(try Data(contentsOf: new.appending(path: "widget.json")) == Data("crumb".utf8))
        #expect(!FileManager.default.fileExists(atPath: new.appending(path: "default.store").path))
        // The real store was never touched by the failed restore — still
        // exactly where the safety net found it, for a later attempt to try
        // again.
        #expect(try Data(contentsOf: sibling.appending(path: "default.store")) == Data("real-store".utf8))
        #expect(FileManager.default.fileExists(atPath: sibling.appending(path: "Meetings/abc").path))
    }
}

/// Stands in for a second Cheerio process winning the exact same rename between
/// this launch's existence checks and its own `moveItem` call. Rather than fake
/// the error `moveItem` would throw, this performs the *real* competing rename on
/// the "other launch's" behalf the moment this launch asks to perform its own,
/// then lets the now-doomed second rename throw for real — an actual
/// reproduction of the interleaving, not a stand-in for one.
private final class RaceSimulatingFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try super.moveItem(at: srcURL, to: dstURL)
        // The caller's own attempt, now racing against a source that's already
        // gone — exactly what a real second launch would produce.
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

/// Lets the set-aside step succeed for real, then fails the very next
/// `moveItem` — the old-to-new rename — without touching the filesystem, to
/// prove the "old is untouched on any failure" guarantee holds even once the
/// first of the two moves has already gone through.
private final class FailsOnTheSecondMoveFileManager: FileManager {
    private var moveCount = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        guard moveCount == 1 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

/// Lets the set-aside move succeed cleanly (this launch wins that step), then
/// applies `RaceSimulatingFileManager`'s trick only to the rename that follows
/// it — a different launch's identical old→new rename wins first, so this
/// launch's own attempt throws against a source that's already gone.
private final class LosesTheRenameRaceAfterSettingAsideFileManager: FileManager {
    private var moveCount = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        guard moveCount > 1 else {
            try super.moveItem(at: srcURL, to: dstURL)
            return
        }
        try super.moveItem(at: srcURL, to: dstURL)
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

/// Simulates a second attempt's *entire* migration completing in the gap
/// between this attempt checking that `new` is bare and this attempt's own
/// move to set it aside — exactly the interleaving the per-process lock
/// exists to make impossible, reproduced here to prove the stranded-store
/// safety net alone still recovers from it. Triggers exactly once, on the
/// first `fileExists` check against `new`'s own path — the precise call site
/// where `attemptMigration` decides whether to set `new` aside — since that's
/// the only moment this attempt reads `new`'s existence before acting on it.
private final class InterleavesAnotherAttemptsCompleteMigrationFileManager: FileManager {
    private let old: URL
    private let new: URL
    private let otherAttemptsSibling: URL
    private var hasInterleaved = false

    init(old: URL, new: URL, otherAttemptsSibling: URL) {
        self.old = old
        self.new = new
        self.otherAttemptsSibling = otherAttemptsSibling
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        if !hasInterleaved, path == new.path {
            hasInterleaved = true
            // The "other attempt," running its own set-aside-then-rename to
            // completion synchronously right here, standing in for the gap a
            // real second process could occupy without the lock.
            try? super.moveItem(at: new, to: otherAttemptsSibling)
            try? super.moveItem(at: old, to: new)
        }
        return super.fileExists(atPath: path)
    }
}

/// Lets `restoreStrandedStore`'s first move (displacing whatever currently
/// occupies `new`) succeed for real, fails its second (landing the
/// store-bearing sibling at `new`) without touching the filesystem, and lets
/// the rollback that follows — moving the displaced directory back into
/// `new` — succeed for real too, so a test can observe the fully-recovered
/// state rather than just the absence of a crash.
private final class FailsRestoringTheStrandedStoreFileManager: FileManager {
    private var moveCount = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        guard moveCount == 2 else {
            try super.moveItem(at: srcURL, to: dstURL)
            return
        }
        throw CocoaError(.fileWriteUnknown)
    }
}
