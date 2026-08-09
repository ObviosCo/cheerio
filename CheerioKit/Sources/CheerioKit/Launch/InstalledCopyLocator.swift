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

    /// - Parameters:
    ///   - candidates: every `.app` bundle found in the directories being
    ///     searched.
    ///   - bundleIdentifier: the running app's own identifier — the only
    ///     thing a candidate is matched on.
    ///   - preferredName: the running bundle's own filename (e.g.
    ///     `"Cheerio.app"`). Breaks a tie among several identifier matches —
    ///     which can genuinely happen if an old copy was renamed rather than
    ///     replaced — by preferring the one that wasn't renamed, since that's
    ///     the more likely "real" install and the one a user would expect
    ///     "Cheerio Is Already Installed" to mean.
    public static func find(
        among candidates: [Candidate], bundleIdentifier: String, preferredName: String
    ) -> String? {
        let matches = candidates.filter { $0.bundleIdentifier == bundleIdentifier }
        guard !matches.isEmpty else { return nil }
        if let exactNameMatch = matches.first(where: {
            URL(fileURLWithPath: $0.path).lastPathComponent == preferredName
        }) {
            return exactNameMatch.path
        }
        return matches.first?.path
    }
}
