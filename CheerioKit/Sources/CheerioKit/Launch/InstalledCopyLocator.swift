import Foundation

/// Picks a stable, already-installed copy of this app out of a set of
/// candidate `.app` bundles — by bundle identifier, not by filename, because
/// an installed copy can be renamed (`Cheerio 2.app`, after a user resolved a
/// name collision by hand) without losing its identity. A locator that only
/// checked for a same-named file would miss a renamed install entirely and
/// offer to create a second copy right next to it.
///
/// Takes candidates as plain data rather than touching the filesystem itself
/// — the caller (`InstalledCopyScan` in the app target) does the actual
/// `/Applications`-and-`~/Applications` directory listing and
/// `Bundle(url:)` reads, both of which are the kind of I/O this package keeps
/// out of its pure decision logic. That split is what makes the matching and
/// tie-breaking rule testable without a real disk.
public enum InstalledCopyLocator {
    /// One `.app` bundle found while scanning a directory.
    public struct Candidate: Sendable {
        public let path: String
        /// `nil` if the bundle couldn't be read at all — nothing recoverable
        /// to compare against, so it can never match.
        public let bundleIdentifier: String?

        public init(path: String, bundleIdentifier: String?) {
            self.path = path
            self.bundleIdentifier = bundleIdentifier
        }
    }

    /// The set ``find(among:acceptableBundleIdentifiers:preferredName:)`` should
    /// treat as "this app," given the identifier the current process is actually
    /// running under.
    ///
    /// Only a process running as `AudioStorage.isRunningAsOfficialBuild` gets
    /// `legacyBundleIdentifier` added to its own — a fork built under its own
    /// identifier matches only that identifier, even if the fork correctly
    /// followed README.md's instructions and changed `AudioStorage.appBundleIdentifier`
    /// to match (`isRunningAsOfficialBuild` deliberately never reads
    /// `appBundleIdentifier` — see its doc comment for why comparing against that
    /// one instead would defeat this gate entirely). Without this gate, a fork
    /// launched from a DMG would find an unrelated, independently-installed
    /// `app.cheerio.mac` copy, treat it as itself already installed, hand off to
    /// that unrelated app, and quit — wrong twice over, since that copy isn't the
    /// fork and the fork was never part of the rename the legacy identifier exists
    /// for in the first place.
    public static func acceptableBundleIdentifiers(
        runningAs identifier: String, legacyBundleIdentifier: String = AudioStorage.legacyBundleIdentifier
    ) -> Set<String> {
        AudioStorage.isRunningAsOfficialBuild(identifier) ? [identifier, legacyBundleIdentifier] : [identifier]
    }

    /// - Parameters:
    ///   - candidates: every `.app` bundle found in the directories being
    ///     searched.
    ///   - acceptableBundleIdentifiers: every identifier that counts as "this
    ///     app" for matching purposes — not always a single value. See
    ///     ``acceptableBundleIdentifiers(runningAs:legacyBundleIdentifier:)``
    ///     for how a caller should build this set; passing just the running
    ///     identifier is always correct too, it just misses the transitional
    ///     match that helper adds during the `co.obvios.cheerio.mac` rename
    ///     (#22).
    ///   - preferredName: the running bundle's own filename (e.g.
    ///     `"Cheerio.app"`). Breaks a tie among several identifier matches —
    ///     which can genuinely happen if an old copy was renamed rather than
    ///     replaced — by preferring the one that wasn't renamed, since that's
    ///     the more likely "real" install and the one a user would expect
    ///     "Cheerio Is Already Installed" to mean.
    public static func find(
        among candidates: [Candidate], acceptableBundleIdentifiers: Set<String>, preferredName: String
    ) -> String? {
        let matches = candidates.filter { candidate in
            candidate.bundleIdentifier.map(acceptableBundleIdentifiers.contains) ?? false
        }
        guard !matches.isEmpty else { return nil }
        if let exactNameMatch = matches.first(where: {
            URL(fileURLWithPath: $0.path).lastPathComponent == preferredName
        }) {
            return exactNameMatch.path
        }
        return matches.first?.path
    }
}
