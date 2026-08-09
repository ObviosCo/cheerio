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

    /// The production incident (#126): an MCP client resolved the helper's store
    /// path — creating nothing but a bare parent directory along the way, in the
    /// version of the helper running that morning — before the rebuilt app had ever
    /// launched to migrate anything. The old guard read that empty directory as
    /// "already migrated" and walked away, stranding the whole library under the
    /// old identifier. The fix: a new directory with no store in it still gets the
    /// old container's contents moved in.
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
    }

    /// A new directory that exists for a reason with nothing to do with migration —
    /// here standing in for a stray file dropped by something else entirely — must
    /// keep that file exactly as it was: the merge only ever moves *old*'s items,
    /// and skips anything whose name already exists at the destination.
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
        #expect(try Data(contentsOf: new.appending(path: "widget.json")) == Data("unrelated".utf8))
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
