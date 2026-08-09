import AppKit
import Foundation

/// The "Move to Applications?" half of issue #56 — a first-party equivalent of
/// the LetsMove pattern, scoped to exactly what Cheerio needs: no
/// self-relaunch-loop detection, no "don't ask again" preference. Neither is
/// needed because `LaunchLocationClassifier` already guarantees this only runs
/// when the current copy is somewhere Sparkle could never have updated it
/// anyway — see `LaunchLocationCheck`.
enum MoveToApplications {
    /// Copies — never moves in place, since the source is typically a
    /// read-only DMG mount or an App Translocation bind mount, neither of
    /// which can be written to — `currentBundleURL` to `/Applications`, under
    /// its own name.
    static func perform(currentBundleURL: URL) -> Result<URL, Error> {
        let destination = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(currentBundleURL.lastPathComponent)
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: destination.path) else {
            // Something put a copy there since `InstalledCopyLocator` last
            // checked — a concurrent launch, most plausibly. Don't clobber it.
            return .failure(MoveToApplicationsError.destinationAlreadyExists)
        }

        do {
            try fileManager.copyItem(at: currentBundleURL, to: destination)
        } catch {
            return .failure(error)
        }

        // Both of these routinely fail — the source is often on read-only
        // media — and neither failure should undo the copy that already
        // succeeded, so both are best-effort. Stripping quarantine means the
        // moved copy won't repeat Gatekeeper's "downloaded from the internet"
        // prompt; trashing the source cleans up the now-empty shell so it
        // doesn't linger in Downloads looking like a second, older Cheerio.
        removeQuarantineAttribute(at: destination)
        try? fileManager.trashItem(at: currentBundleURL, resultingItemURL: nil)

        return .success(destination)
    }

    /// Launches the just-moved copy. Doesn't deliver a URL — there's nothing
    /// for it to act on beyond simply starting, so this is `openApplication`
    /// rather than `ActivateInstalledCopy`'s `open(_:withApplicationAt:)`.
    static func relaunch(at url: URL) {
        NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil
        )
    }

    private static func removeQuarantineAttribute(at url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.quarantineProperties = nil
        try? mutableURL.setResourceValues(values)
    }
}

enum MoveToApplicationsError: LocalizedError {
    case destinationAlreadyExists

    var errorDescription: String? {
        switch self {
        case .destinationAlreadyExists:
            "Applications already has a copy of Cheerio."
        }
    }
}
