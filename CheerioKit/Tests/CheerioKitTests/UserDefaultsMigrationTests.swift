import Foundation
import Testing

@testable import CheerioKit

/// Exercises ``UserDefaultsMigration`` against synthetic `UserDefaults` suites, never
/// the real `app.cheerio.mac` or `co.obvios.cheerio.mac` domains — each test mints its
/// own throwaway domain name and removes it again in `defer`, so a run of this suite
/// can't leave anything behind in `~/Library/Preferences`.
@Suite struct UserDefaultsMigrationTests {
    /// A fresh, uniquely-named domain and the `UserDefaults` bound to it.
    /// `persistentDomain(forName:)` and `removePersistentDomain(forName:)` both
    /// operate on the domain by name, not on the instance that created it — which is
    /// exactly the property ``UserDefaultsMigration`` relies on to read a domain that
    /// isn't its caller's own.
    private func makeDomain() -> (name: String, defaults: UserDefaults) {
        let name = "cheerio-test-\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    private func cleanUp(_ names: String...) {
        for name in names {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
    }

    @Test func copiesEveryLegacyKeyNotAlreadyPresent() {
        let (oldName, oldDefaults) = makeDomain()
        let (newName, newDefaults) = makeDomain()
        defer { cleanUp(oldName, newName) }

        oldDefaults.set(true, forKey: "onboardingHasCompleted")
        oldDefaults.set(7, forKey: "audioRetentionDays")
        oldDefaults.set(true, forKey: "SUEnableAutomaticChecks")

        let copied = UserDefaultsMigration.migrateIfNeeded(legacyDomain: oldName, defaults: newDefaults)

        #expect(copied == 3)
        #expect(newDefaults.bool(forKey: "onboardingHasCompleted"))
        #expect(newDefaults.integer(forKey: "audioRetentionDays") == 7)
        #expect(newDefaults.bool(forKey: "SUEnableAutomaticChecks"))
    }

    @Test func neverOverwritesAValueAlreadySetUnderTheNewIdentifier() {
        let (oldName, oldDefaults) = makeDomain()
        let (newName, newDefaults) = makeDomain()
        defer { cleanUp(oldName, newName) }

        oldDefaults.set(30, forKey: "audioRetentionDays")
        newDefaults.set(1, forKey: "audioRetentionDays")

        _ = UserDefaultsMigration.migrateIfNeeded(legacyDomain: oldName, defaults: newDefaults)

        #expect(newDefaults.integer(forKey: "audioRetentionDays") == 1)
    }

    @Test func isIdempotentAcrossRelaunches() {
        let (oldName, oldDefaults) = makeDomain()
        let (newName, newDefaults) = makeDomain()
        defer { cleanUp(oldName, newName) }

        oldDefaults.set(true, forKey: "onboardingHasCompleted")
        let firstRun = UserDefaultsMigration.migrateIfNeeded(legacyDomain: oldName, defaults: newDefaults)
        #expect(firstRun == 1)

        // The old value changes after migration (e.g. the user still has an old
        // build running somewhere): a second run must not re-copy it, because the
        // flag lives on `newDefaults`, not `oldDefaults`.
        oldDefaults.set(false, forKey: "onboardingHasCompleted")
        let secondRun = UserDefaultsMigration.migrateIfNeeded(legacyDomain: oldName, defaults: newDefaults)

        #expect(secondRun == 0)
        #expect(newDefaults.bool(forKey: "onboardingHasCompleted"))
    }

    @Test func noLegacyDomainIsANoOp() {
        let (newName, newDefaults) = makeDomain()
        defer { cleanUp(newName) }

        let copied = UserDefaultsMigration.migrateIfNeeded(
            legacyDomain: "nonexistent.\(UUID().uuidString)", defaults: newDefaults
        )

        #expect(copied == 0)
    }
}
