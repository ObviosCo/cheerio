import AppKit

/// Hands off to a stable copy of Cheerio already at `installedBundlePath`,
/// whether that copy is currently running or not.
enum ActivateInstalledCopy {
    /// What actually happened, so the panel can say something true rather
    /// than assume the handoff worked. `String`, not `Error`, on the failure
    /// case — an existential `Error` isn't `Sendable`, and this only ever
    /// needs to be displayed, never inspected as a typed error.
    enum Outcome: Sendable {
        /// The installed copy is new enough to have `CheckForUpdatesRequest`'s
        /// handler, and Launch Services confirmed the request went through —
        /// `NSWorkspace.open(_:withApplicationAt:)` launches it if needed and
        /// delivers the URL either way (see that type's doc comment for why
        /// one call covers both).
        case activated
        /// First-rollout back-compat: the installed copy predates the
        /// handler, so opening the URL at it would just launch or activate
        /// the app and nothing would call `checkForUpdates()` there — the
        /// whole point of the button that led here. Brought to the front
        /// anyway (there's no reason not to), but told nothing.
        case installedCopyTooOldForHandoff
        /// Launch Services itself failed — the installed copy couldn't be
        /// reached at all, new enough or not.
        case handoffFailed(String)
    }

    /// The first version to ship `CheckForUpdatesRequest`'s `cheerio://`
    /// handler (issue #56/#80) — **do not** move this with the build version.
    /// A moving "whatever's currently running" threshold was the original,
    /// wrong design: once a real release ships the handler, an installed copy
    /// exactly one version behind the *next* build would still have it, but
    /// would compare as older than that build and wrongly fall back to
    /// manual instructions forever. A fixed version has the opposite,
    /// self-correcting failure mode instead — it can only be wrong once, at
    /// the moment this ships, and only in the safe direction (too
    /// pessimistic, never too optimistic).
    ///
    /// 26.8.9 is the last published release (see `site/download.html`) as of
    /// this PR; this one PR-worth of code hasn't shipped in any tag yet, so
    /// 26.8.10 is a placeholder for "whichever tag actually carries it,"
    /// picked as the next plausible one. **If the real tag differs — a
    /// skipped micro number, a month rollover — the release checklist in
    /// `.github/workflows/release.yml`'s header is what has to catch updating
    /// this string; nothing here derives it automatically or would notice a
    /// mismatch on its own.** Delete this whole gate, including
    /// `Outcome.installedCopyTooOldForHandoff`, once no realistically-running
    /// copy could predate it.
    private static let firstVersionWithCheckForUpdatesHandler = "26.8.10"

    /// `async` rather than a completion handler: `NSWorkspace`'s own
    /// Objective-C completion-handler methods require a `@Sendable` block,
    /// which would force every caller's closure — down to `LaunchLocationCheck`'s
    /// captured `@MainActor` state — into the same annotation for no real
    /// safety benefit, since everything here already runs on the main actor.
    /// The compiler-synthesized `async throws` overloads sidestep that
    /// entirely.
    static func activateAndCheckForUpdates(installedBundlePath: String) async -> Outcome {
        let installedBundleURL = URL(fileURLWithPath: installedBundlePath)
        let installedVersion = Bundle(url: installedBundleURL)?.shortVersionString

        // `nil` (unreadable `Info.plist`) is treated the same as "older" —
        // there's nothing to trust it on, so the safer assumption is the one
        // that doesn't claim a check started.
        guard let installedVersion,
            installedVersion.compare(firstVersionWithCheckForUpdatesHandler, options: .numeric)
                != .orderedAscending
        else {
            // Too old either way — a launch failure here changes nothing
            // about which instruction the user needs, so the result is
            // discarded.
            _ = try? await NSWorkspace.shared.openApplication(
                at: installedBundleURL, configuration: NSWorkspace.OpenConfiguration()
            )
            return .installedCopyTooOldForHandoff
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open(
                [CheckForUpdatesRequest.url], withApplicationAt: installedBundleURL, configuration: configuration
            )
            return .activated
        } catch {
            return .handoffFailed(error.localizedDescription)
        }
    }
}

extension Bundle {
    fileprivate var shortVersionString: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
