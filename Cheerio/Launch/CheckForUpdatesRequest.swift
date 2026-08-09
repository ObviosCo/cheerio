import AppKit

/// The URL `ActivateInstalledCopy` hands to a stable copy of Cheerio, and the
/// handler that copy's own `.onOpenURL` (see `CheerioApp`) calls in response.
///
/// A custom scheme rather than Distributed Notifications or a launch argument:
/// both of those only reach a process that is already listening, or one we are
/// actively launching ourselves — and `LaunchLocationCheck` doesn't know in
/// advance which of those is true for the installed copy. `NSWorkspace.open(_:
/// withApplicationAt:)` resolves that ambiguity on its own — it launches the
/// app if needed and delivers a URL either way — so this only has to be
/// something that survives the trip.
enum CheckForUpdatesRequest {
    static let url = URL(string: "cheerio://check-for-updates")!

    @MainActor
    static func handle(_ url: URL, updater: AppUpdater) {
        guard url == Self.url else { return }
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }
}
