import AppKit

/// Hands off to a stable copy of Cheerio already at `installedBundlePath`,
/// whether that copy is currently running or not.
enum ActivateInstalledCopy {
    /// What actually happened, so the panel can say something true rather
    /// than assume the handoff worked.
    enum Outcome {
        /// The installed copy is new enough to have `CheckForUpdatesRequest`'s
        /// handler; the handoff was sent — `NSWorkspace.open(_:withApplicationAt:)`
        /// launches it if needed and delivers the URL either way (see that
        /// type's doc comment for why one call covers both).
        case activated
        /// First-rollout back-compat: the installed copy predates the
        /// handler, so opening the URL at it would just launch or activate
        /// the app and nothing would call `checkForUpdates()` there — the
        /// whole point of the button that led here. Brought to the front
        /// anyway (there's no reason not to), but told nothing.
        case installedCopyTooOldForHandoff
    }

    /// This build's own version, standing in for "the first version with the
    /// handler." There is no real historical version number to compare
    /// against — this handler doesn't exist in any released build yet — so
    /// the only trustworthy threshold is the version of whichever build is
    /// asking the question right now: it has the handler by definition
    /// (this file is part of it), so anything *older* than it necessarily
    /// predates it, and anything the same age or newer can be assumed to
    /// carry it too. Once enough time has passed that no realistically
    /// running copy could predate this feature, this whole version gate
    /// becomes dead weight and can be deleted — `activateAndCheckForUpdates`
    /// would just always return `.activated`.
    private static var runningBuildVersion: String { Bundle.main.shortVersionString ?? "0.0.0" }

    static func activateAndCheckForUpdates(installedBundlePath: String) -> Outcome {
        let installedBundleURL = URL(fileURLWithPath: installedBundlePath)
        let installedVersion = Bundle(url: installedBundleURL)?.shortVersionString

        // `nil` (unreadable `Info.plist`) is treated the same as "older" —
        // there's nothing to trust it on, so the safer assumption is the one
        // that doesn't claim a check started.
        guard let installedVersion,
            installedVersion.compare(runningBuildVersion, options: .numeric) != .orderedAscending
        else {
            NSWorkspace.shared.openApplication(
                at: installedBundleURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil
            )
            return .installedCopyTooOldForHandoff
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [CheckForUpdatesRequest.url],
            withApplicationAt: installedBundleURL,
            configuration: configuration,
            completionHandler: nil
        )
        return .activated
    }
}

extension Bundle {
    fileprivate var shortVersionString: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
