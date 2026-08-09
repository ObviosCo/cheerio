import Foundation

/// What, if anything, to tell the user about where this copy of Cheerio is
/// running from.
public enum LaunchAdvisory: Equatable, Sendable {
    /// Nothing to do — `LaunchLocation.normal`, so silent, including for a dev
    /// build run straight out of a build directory.
    case none
    /// A stable copy already exists; `installedBundlePath` is where. Offering
    /// to move would just produce a second Cheerio, so the right move is to
    /// point at the one that's already there instead.
    case alreadyInstalled(installedBundlePath: String)
    /// No stable copy anywhere — offer to create one.
    case offerMoveToApplications
}

/// The decision table behind issue #56, kept as a pure function of the two
/// facts that matter: is this launch somewhere Sparkle can't reach next time,
/// and does a stable copy already exist. Everything about *how* those two
/// facts get established — reading the bundle's path and quarantine state,
/// scanning `/Applications` for a bundle-identifier match — is AppKit-adjacent
/// I/O that belongs in the app target, not here.
public enum LaunchAdvisoryClassifier {
    /// - Parameters:
    ///   - location: classification of the *running* bundle's own path.
    ///   - installedBundlePath: the resolved path of a matching bundle already
    ///     under `/Applications`, if the caller found one — including, as a
    ///     degenerate case, one identical to the running bundle's own path.
    ///     Nothing here needs to special-case that: whatever the caller does
    ///     with `.alreadyInstalled` turns out to be the right action regardless
    ///     of whether the path it names is some other process or this one.
    public static func advise(location: LaunchLocation, installedBundlePath: String?) -> LaunchAdvisory {
        guard location != .normal else { return .none }
        if let installedBundlePath {
            return .alreadyInstalled(installedBundlePath: installedBundlePath)
        }
        return .offerMoveToApplications
    }
}
