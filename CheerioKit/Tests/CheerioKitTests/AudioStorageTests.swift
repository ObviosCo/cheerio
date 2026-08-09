import Testing

@testable import CheerioKit

/// `AudioStorage.isRunningAsCanonicalIdentifier` is the one predicate every piece of
/// fork-sensitive machinery shares: the bundle-identifier migration, the UserDefaults
/// migration, and the DMG launch-location handoff's transitional identifier match all
/// gate on it, so it's worth pinning on its own rather than only indirectly through
/// each of those.
@Suite struct AudioStorageTests {
    @Test func theCanonicalIdentifierIsCanonical() {
        #expect(AudioStorage.isRunningAsCanonicalIdentifier(AudioStorage.appBundleIdentifier))
    }

    @Test func theLegacyIdentifierIsNotCanonical() {
        // The whole point of the gate: an install still carrying the pre-rename
        // identifier hasn't yet become "canonical" from this process's point of
        // view — that transition happens through `BundleIdentifierMigration`, not by
        // this predicate treating the old identifier as good enough.
        #expect(!AudioStorage.isRunningAsCanonicalIdentifier(AudioStorage.legacyBundleIdentifier))
    }

    @Test func aForksOwnIdentifierIsNotCanonical() {
        #expect(!AudioStorage.isRunningAsCanonicalIdentifier("com.example.myfork.cheerio"))
    }

    @Test func aMissingIdentifierIsNotCanonical() {
        #expect(!AudioStorage.isRunningAsCanonicalIdentifier(nil))
    }
}
