import Foundation
import Testing

@testable import CheerioKit

/// `AudioStorage.isRunningAsOfficialBuild` is the one predicate every piece of
/// fork-sensitive machinery shares: the bundle-identifier migration, the UserDefaults
/// migration, and the DMG launch-location handoff's transitional identifier match all
/// gate on it, so it's worth pinning on its own rather than only indirectly through
/// each of those.
@Suite struct AudioStorageTests {
    @Test func theOfficialIdentifierIsOfficial() {
        #expect(AudioStorage.isRunningAsOfficialBuild(AudioStorage.officialBundleIdentifier))
    }

    @Test func theLegacyIdentifierIsNotOfficial() {
        // The whole point of the gate: an install still carrying the pre-rename
        // identifier hasn't yet become "official" from this process's point of
        // view — that transition happens through `BundleIdentifierMigration`, not by
        // this predicate treating the old identifier as good enough.
        #expect(!AudioStorage.isRunningAsOfficialBuild(AudioStorage.legacyBundleIdentifier))
    }

    @Test func aForksOwnIdentifierIsNotOfficial() {
        #expect(!AudioStorage.isRunningAsOfficialBuild("com.example.myfork.cheerio"))
    }

    @Test func aMissingIdentifierIsNotOfficial() {
        #expect(!AudioStorage.isRunningAsOfficialBuild(nil))
    }

    /// The exact bug Copilot's review of #111 caught: a *correctly configured* fork
    /// follows README.md's instructions and sets `appBundleIdentifier` to its own
    /// identifier — so its runtime identifier and its own `appBundleIdentifier` are
    /// the same string by construction. If `isRunningAsOfficialBuild` compared
    /// against `appBundleIdentifier`, this scenario would come back `true` and
    /// silently re-enable the `app.cheerio.mac` migration and the DMG handoff's
    /// legacy match for a fork that never shipped under that identifier. It compares
    /// against the separate, fixed `officialBundleIdentifier` instead, so a fork
    /// answers `false` here regardless of what it did to `appBundleIdentifier`.
    @Test func aCorrectlyConfiguredForksOwnIdentifierIsStillNotOfficial() {
        let forksChosenIdentifier = "com.example.myfork.cheerio"
        // What the fork's README-following maintainer would have set
        // `appBundleIdentifier` to, and what `Bundle.main.bundleIdentifier` reports
        // at runtime for that same build — deliberately the identical string, to
        // reproduce the scenario exactly.
        #expect(!AudioStorage.isRunningAsOfficialBuild(forksChosenIdentifier))
    }

    /// What `BundleIdentifierMigration.Outcome.storeStrandedInSibling` depends
    /// on: `setContainerOverride` takes any directory name, not specifically a
    /// bundle identifier, and everything built on `applicationSupport()` —
    /// `storeURL()` included — resolves it exactly the same way either way,
    /// with no shape validation to generalize. `CheerioApp.init` passes a
    /// `pre-migration-*` sibling's own directory name here when the migration
    /// reports that outcome; this is what makes doing so actually open the
    /// real store sitting in that sibling, rather than a container by that
    /// name that doesn't exist.
    @Test func containerOverrideResolvesIntoAnArbitraryDirectoryNameNotJustABundleIdentifier() throws {
        let siblingName = "cheerio.test.pre-migration-\(UUID().uuidString)"
        AudioStorage.setContainerOverride(siblingName)
        let store = try AudioStorage.storeURL()
        defer {
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
            AudioStorage.setContainerOverride(nil)
        }

        #expect(store.deletingLastPathComponent().lastPathComponent == siblingName)
        #expect(store.lastPathComponent == AudioStorage.storeFileName)
    }
}
