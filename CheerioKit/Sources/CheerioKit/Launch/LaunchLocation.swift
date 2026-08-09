import Foundation

/// Where the running app bundle sits, as far as Sparkle's ability to find it
/// again at the next launch is concerned. `.dmg` and `.downloaded` are both
/// dead ends for that: a DMG's copy disappears the moment the volume
/// unmounts, and a translocated or still-quarantined copy sits under a path
/// that either won't exist next launch (App Translocation mounts a new
/// randomized directory every time) or isn't one Cheerio put itself in on
/// purpose.
public enum LaunchLocation: Equatable, Sendable {
    /// A stable path — `/Applications`, a build directory, anywhere the app
    /// will still be at the next launch.
    case normal
    /// Still mounted from the disk image it was opened from.
    case dmg
    /// Quarantined, translocated, or both — Gatekeeper still treats this copy
    /// as a fresh download rather than something the user installed.
    case downloaded
}

/// Turns the raw signals a caller can read from the filesystem into a
/// ``LaunchLocation``. Kept free of any actual filesystem or extended-attribute
/// access — issue #56 calls that out explicitly as the boundary to test on its
/// own, separate from the AppKit/NSWorkspace code that gathers the inputs and
/// acts on the answer.
public enum LaunchLocationClassifier {
    /// - Parameters:
    ///   - bundlePath: the running bundle's path, with symlinks already
    ///     resolved by the caller — this only ever does string matching on it.
    ///   - isQuarantined: whether `com.apple.quarantine` (or the equivalent
    ///     `URLResourceValues.quarantineProperties`) is set on the bundle.
    ///     Copying a bundle in Finder preserves extended attributes, so a
    ///     Gatekeeper-approved app dragged into `/Applications` routinely
    ///     keeps this flag forever — approval clears the *prompt*, not the
    ///     xattr. Treated as unstable everywhere except
    ///     `isInApplicationsDirectory`, below, for exactly that reason: without
    ///     that carve-out, a completely normal installed launch misclassifies
    ///     as `.downloaded`, `InstalledCopyLocator` then finds that same
    ///     bundle as "the installed copy," and the already-installed panel
    ///     appears on every single launch of the one true copy.
    ///   - isOnReadOnlyVolume: whether the volume containing `bundlePath` is
    ///     mounted read-only. A necessary condition for "sitting on a DMG,"
    ///     but not sufficient on its own — see `hasPrefix("/Volumes/")` below,
    ///     which rules out the boot volume's own read-only system snapshot.
    ///   - isInApplicationsDirectory: whether `bundlePath` is under
    ///     `/Applications` or `~/Applications` — the caller's
    ///     `InstalledCopyLocator` scan is the source of truth for exactly
    ///     which directories those are. Only suppresses the quarantine
    ///     signal; translocation and a DMG mount are unstable regardless of
    ///     where the path happens to land, though in practice neither ever
    ///     resolves to an Applications directory in the first place.
    public static func classify(
        bundlePath: String, isQuarantined: Bool, isOnReadOnlyVolume: Bool, isInApplicationsDirectory: Bool
    ) -> LaunchLocation {
        if isTranslocated(bundlePath: bundlePath) {
            return .downloaded
        }
        if isOnReadOnlyVolume && bundlePath.hasPrefix("/Volumes/") {
            return .dmg
        }
        if isQuarantined && !isInApplicationsDirectory {
            return .downloaded
        }
        return .normal
    }

    /// Gatekeeper's App Translocation mounts a quarantined app under a
    /// per-launch randomized directory inside `/private/var/folders` — the one
    /// detail issue #56 names explicitly, because unlike the quarantine
    /// attribute it isn't exposed through a resource-value key, only through
    /// the path itself.
    static func isTranslocated(bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/private/var/folders/") && bundlePath.contains("/AppTranslocation/")
    }
}
