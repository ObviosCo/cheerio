import CheerioKit
import Foundation

/// The macOS-specific half of finding an installed copy: which directories to
/// search, how to list them, and how to read a candidate's bundle identifier.
/// The matching and tie-breaking rule itself is `CheerioKit.InstalledCopyLocator`
/// — this only gathers the plain data that logic runs over.
enum InstalledCopyScan {
    /// `/Applications` and, if it exists, `~/Applications` — the two places
    /// macOS itself offers to put an app. Finder's own "Move to Applications"
    /// targets the former; the per-user folder exists for machines where the
    /// current account can't write there, and isn't created by default, which
    /// is why it's only included when something has actually put it there.
    ///
    /// Also the answer to `LaunchLocationClassifier`'s `isInApplicationsDirectory`
    /// — both questions ("is this bundle installed somewhere stable" and "is
    /// the *running* bundle already in one of those places") have to agree on
    /// what counts as "Applications," or the classifier and the locator could
    /// disagree about the same launch.
    static func searchDirectories() -> [URL] {
        var directories = [URL(fileURLWithPath: "/Applications")]
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
        if FileManager.default.fileExists(atPath: userApplications.path) {
            directories.append(userApplications)
        }
        return directories
    }

    /// Whether `bundlePath` sits inside one of `searchDirectories()` — used to
    /// suppress a quarantine attribute that survived being Finder-copied into
    /// an already-installed location. See `LaunchLocationClassifier`'s doc
    /// comment on `isQuarantined` for why that carve-out exists at all.
    static func isInApplicationsDirectory(bundlePath: String) -> Bool {
        searchDirectories().contains { bundlePath.hasPrefix($0.path + "/") }
    }

    /// `nil` if no `/Applications`-or-`~/Applications` bundle shares this
    /// app's bundle identifier — or, transitionally, the pre-`co.obvios`
    /// identifier, since an installed copy that hasn't relaunched since the
    /// rename still carries that one — but only when this process is actually
    /// running as Cheerio's own canonical build. A fork built under its own
    /// identifier matches only that identifier: it never shipped under the old
    /// one, so an unrelated app that happens to use it is not "itself,
    /// already installed." See
    /// `InstalledCopyLocator.acceptableBundleIdentifiers(runningAs:)`.
    static func find() -> String? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        return InstalledCopyLocator.find(
            among: candidates(in: searchDirectories()),
            acceptableBundleIdentifiers: InstalledCopyLocator.acceptableBundleIdentifiers(runningAs: identifier),
            preferredName: Bundle.main.bundleURL.lastPathComponent
        )
    }

    private static func candidates(in directories: [URL]) -> [InstalledCopyLocator.Candidate] {
        directories.flatMap { directory -> [InstalledCopyLocator.Candidate] in
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            return (entries ?? [])
                .filter { $0.pathExtension == "app" }
                .map { url in
                    InstalledCopyLocator.Candidate(
                        path: url.resolvingSymlinksInPath().path,
                        bundleIdentifier: Bundle(url: url)?.bundleIdentifier
                    )
                }
        }
    }
}
