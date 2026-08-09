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
    ///   - isOnReadOnlyVolume: whether the volume containing `bundlePath` is
    ///     mounted read-only. A necessary condition for "sitting on a DMG,"
    ///     but not sufficient on its own — see `hasPrefix("/Volumes/")` below,
    ///     which rules out the boot volume's own read-only system snapshot.
    public static func classify(bundlePath: String, isQuarantined: Bool, isOnReadOnlyVolume: Bool)
        -> LaunchLocation
    {
        if isQuarantined || isTranslocated(bundlePath: bundlePath) {
            return .downloaded
        }
        if isOnReadOnlyVolume && bundlePath.hasPrefix("/Volumes/") {
            return .dmg
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
