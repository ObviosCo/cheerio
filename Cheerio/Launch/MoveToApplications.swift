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
    /// its own name. Falls back to `~/Applications` if that fails: a standard
    /// (non-admin) account can't write to `/Applications` at all, and this
    /// package already treats `~/Applications` as an equally stable install
    /// location (`InstalledCopyScan.searchDirectories()`) rather than asking
    /// for admin authorization, which would need a password prompt for
    /// something the user didn't otherwise have to authenticate for.
    static func perform(currentBundleURL: URL) -> Result<URL, Error> {
        switch copy(currentBundleURL, to: URL(fileURLWithPath: "/Applications")) {
        case .success(let destination):
            return .success(destination)
        case .failure(let systemApplicationsError):
            let userApplications = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications")
            try? FileManager.default.createDirectory(at: userApplications, withIntermediateDirectories: true)
            switch copy(currentBundleURL, to: userApplications) {
            case .success(let destination):
                return .success(destination)
            case .failure:
                // The /Applications failure is almost always the informative
                // one (a permissions error); if the per-user fallback failed
                // too it's usually the same underlying problem restated (a
                // full disk, say), so that's the error worth surfacing.
                return .failure(systemApplicationsError)
            }
        }
    }

    private static func copy(_ currentBundleURL: URL, to directory: URL) -> Result<URL, Error> {
        let destination = directory.appendingPathComponent(currentBundleURL.lastPathComponent)
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: destination.path) else {
            // Something put a copy there since `InstalledCopyScan` last
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
    ///
    /// `async`, returning the failure description rather than firing and
    /// forgetting: the caller exits this (source) process right after
    /// relaunching, and needs to know whether Launch Services actually
    /// managed it before doing so — a copy that failed to launch would
    /// otherwise leave the user with no running Cheerio at all, reported as a
    /// success. `String?`, not `Error?`, for the same reason as
    /// `ActivateInstalledCopy.Outcome.handoffFailed` — this is only ever
    /// shown, never inspected, and an existential `Error` isn't `Sendable`.
    static func relaunch(at url: URL) async -> String? {
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration()
            )
            return nil
        } catch {
            return error.localizedDescription
        }
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
