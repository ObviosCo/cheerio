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
}
