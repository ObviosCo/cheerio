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
}

/// `AudioStorage.setContainerOverride` is a process-global `Mutex`, by design (see
/// its own doc comment) — which makes it the one piece of `AudioStorage` state a
/// test can't touch the way the rest of this file does. `.serialized` because
/// Swift Testing otherwise runs every suite's tests concurrently by default, and
/// this suite's own test setting the override races any *other* test reading
/// `AudioStorage.applicationSupport()` (directly, or through anything built on
/// it) while that override is live — `CallbackPayloadTests`' equivalent test lives
/// here rather than there for exactly that reason, since it makes two separate
/// calls through `applicationSupport()` and compares them, which only holds if
/// the override can't change in between.
@Suite(.serialized) struct ContainerOverrideTests {
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

    /// Moved from `CallbackPayloadTests`: this makes two independent calls
    /// through `AudioStorage.applicationSupport()` (one via
    /// `CallbackPayload.defaultDirectory()`, one directly) and compares them,
    /// which is only sound if the container override can't change between the
    /// two — true within this serialized suite, not guaranteed against a test
    /// anywhere else in the target setting it concurrently.
    @Test func defaultDirectoryLivesUnderApplicationSupport() throws {
        let directory = try CallbackPayload.defaultDirectory()
        let applicationSupport = try AudioStorage.applicationSupport()
        #expect(directory.path.hasPrefix(applicationSupport.path))
        #expect(directory.lastPathComponent == "Callbacks")
    }
}
