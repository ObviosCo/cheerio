import Foundation

/// Looks for a stable copy of this same app already sitting in `/Applications`
/// — the one location `LaunchLocationCheck` treats as "already installed."
///
/// Matches on bundle identifier, not just a same-named file at that path: a
/// same-named decoy, or a leftover directory from an app that used to live
/// there, shouldn't read as an install.
enum InstalledCopyLocator {
    /// `nil` if `/Applications` has nothing at that name, or has something
    /// there that isn't this app.
    static func find() -> String? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let name = Bundle.main.bundleURL.lastPathComponent
        let candidate = URL(fileURLWithPath: "/Applications").appendingPathComponent(name)

        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        guard let candidateBundle = Bundle(url: candidate), candidateBundle.bundleIdentifier == identifier
        else {
            return nil
        }

        return candidate.resolvingSymlinksInPath().path
    }
}
