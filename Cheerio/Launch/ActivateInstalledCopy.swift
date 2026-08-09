import AppKit

/// Hands off to a stable copy of Cheerio already at `installedBundlePath`,
/// whether that copy is currently running or not.
///
/// `NSWorkspace.open(_:withApplicationAt:)` covers both cases with one call: it
/// launches the app if it isn't running, and either way delivers
/// `CheckForUpdatesRequest.url` to it via the ordinary open-URL path, which is
/// what actually calls `AppUpdater.checkForUpdates()` over there (see
/// `CheerioApp`'s `.onOpenURL`). That also covers the degenerate case
/// `LaunchAdvisory.alreadyInstalled`'s doc comment mentions — `installedBundlePath`
/// happening to be this very process — without any special-casing here: opening
/// a URL "at" an app that's already running at that exact path just delivers
/// the URL to it, and it makes no difference to LaunchServices whether that
/// running process is us.
enum ActivateInstalledCopy {
    static func activateAndCheckForUpdates(installedBundlePath: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [CheckForUpdatesRequest.url],
            withApplicationAt: URL(fileURLWithPath: installedBundlePath),
            configuration: configuration,
            completionHandler: nil
        )
    }
}
