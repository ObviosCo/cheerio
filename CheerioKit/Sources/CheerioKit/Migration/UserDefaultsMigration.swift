import Foundation
import OSLog

/// One-time copy of every preference Cheerio wrote under the old bundle identifier
/// (``AudioStorage/legacyBundleIdentifier``) into the new one
/// (``AudioStorage/appBundleIdentifier``), so the `co.obvios` rename doesn't reset
/// onboarding, retention, recording mode, the notification ledger, or Sparkle's own
/// settings back to their defaults.
///
/// `UserDefaults.standard` (and `@AppStorage`) resolve to whatever `Bundle.main`'s
/// identifier is *right now* — the new one, in a build with the new
/// `PRODUCT_BUNDLE_IDENTIFIER` — so this only ever needs to run forward, old into
/// new, never the reverse.
///
/// Reads the old domain with `persistentDomain(forName:)` rather than
/// `UserDefaults(suiteName:)`: the latter is documented for App Group suites and
/// only happens to also work for reading an arbitrary application's domain by name,
/// while `persistentDomain(forName:)` is the API actually specified for that and
/// needs no throwaway `UserDefaults` instance pointed at someone else's suite.
///
/// Copies every key wholesale, including Sparkle's `SU*` settings. Checked against
/// Sparkle 2.9.5's source before deciding that was safe: none of the keys
/// `AppUpdater` exercises (`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, the
/// last-check timestamp, the skipped-version record) embed the bundle identifier
/// into the *key name* for a `SPUStandardUpdaterController` updating its own host —
/// that suffixed form exists only for an external updater whose main bundle differs
/// from the host it updates (`SUAppcastDriver.m`'s
/// `initialFailedFeedSigningValidationDateKey`), which is not Cheerio's setup. A
/// blanket copy is safe here.
public enum UserDefaultsMigration {
    /// Stamped on the *new* domain once migration has run, so a relaunch never
    /// re-copies — including never overwriting a value the user has since changed
    /// under the new identifier with the stale one from the old.
    static let migratedFlagKey = "legacyBundleIdentifierDefaultsMigrated"

    private static let log = Logger(subsystem: AudioStorage.appBundleIdentifier, category: "UserDefaultsMigration")

    /// Returns how many keys were copied, for a caller that wants to log it.
    /// Idempotent: a second call, or a call with nothing left to copy, copies nothing
    /// and returns 0.
    @discardableResult
    public static func migrateIfNeeded(
        legacyDomain: String = AudioStorage.legacyBundleIdentifier,
        defaults: UserDefaults = .standard
    ) -> Int {
        guard !defaults.bool(forKey: migratedFlagKey) else { return 0 }
        defer { defaults.set(true, forKey: migratedFlagKey) }

        guard let legacyValues = defaults.persistentDomain(forName: legacyDomain), !legacyValues.isEmpty else {
            return 0
        }

        var copied = 0
        for (key, value) in legacyValues where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        if copied > 0 {
            log.notice("Copied \(copied, privacy: .public) preference(s) from the old bundle identifier's domain.")
        }
        return copied
    }
}
