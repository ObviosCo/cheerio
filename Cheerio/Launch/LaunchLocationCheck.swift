import AppKit
import CheerioKit
import OSLog

/// Runs once at launch, ahead of any window opening, to catch the two ways a
/// downloaded build ends up somewhere Sparkle can never update it: still
/// quarantined or translocated, or still sitting on the DMG it was opened
/// from. From a real incident (2026-08-08): a user with Cheerio installed and
/// running downloaded a new build and hit Finder's un-customizable "can't be
/// replaced because Cheerio is open" error mid-drag — issue #56. Both cases get
/// the fix LetsMove popularized, moving the app to a stable location, except
/// when a stable copy already exists, where moving would just produce a
/// second Cheerio; that case instead points at the copy that's already there
/// and quits this one, so the two can never collide over a drag-and-drop again.
///
/// A dev build run from DerivedData or any other build directory is
/// `LaunchLocation.normal` — not quarantined, not translocated, not on a
/// read-only volume — so `LaunchAdvisoryClassifier.advise` returns `.none` and
/// `runIfNeeded()` is a silent no-op, exactly as issue #56 requires.
@MainActor
enum LaunchLocationCheck {
    private static let log = Logger(subsystem: "app.cheerio.mac", category: "Launch")

    /// May terminate the process — via `exit(0)`, not `NSApp.terminate(_:)`,
    /// because this runs from `CheerioApp.init()`, before there's a running
    /// app with a termination sequence to invoke. Every path that hands off to
    /// a *different* stable copy, or that successfully relaunches a
    /// newly-moved one, ends the process this way rather than let two
    /// Cheerios run at once.
    static func runIfNeeded() {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let location = LaunchLocationClassifier.classify(
            bundlePath: bundleURL.path,
            isQuarantined: isQuarantined(bundleURL),
            isOnReadOnlyVolume: isOnReadOnlyVolume(bundleURL),
            isInApplicationsDirectory: InstalledCopyScan.isInApplicationsDirectory(bundlePath: bundleURL.path)
        )
        let advisory = LaunchAdvisoryClassifier.advise(
            location: location, installedBundlePath: InstalledCopyScan.find()
        )

        switch advisory {
        case .none:
            return
        case .alreadyInstalled(let installedBundlePath):
            log.notice(
                "Launched \(String(describing: location), privacy: .public) with an installed copy at \(installedBundlePath, privacy: .public); asking before doing anything."
            )
            presentAlreadyInstalledPanel(installedBundlePath: installedBundlePath)
        case .offerMoveToApplications:
            log.notice(
                "Launched \(String(describing: location), privacy: .public) with no installed copy found; offering to move."
            )
            presentMoveToApplicationsPanel(currentBundleURL: bundleURL)
        }
    }

    private static func presentAlreadyInstalledPanel(installedBundlePath: String) {
        let alert = NSAlert()
        alert.messageText = "Cheerio Is Already Installed"
        alert.informativeText =
            "It updates itself — you don't need to re-download. This copy will quit; the installed one can check for the latest version."
        alert.addButton(withTitle: "Check for Updates")
        alert.addButton(withTitle: "Quit")

        // Never silently relaunch anything — both buttons are a choice the
        // user made, and both end with this (unstable) copy gone.
        if alert.runModal() == .alertFirstButtonReturn {
            switch ActivateInstalledCopy.activateAndCheckForUpdates(installedBundlePath: installedBundlePath) {
            case .activated:
                break
            case .installedCopyTooOldForHandoff:
                // The button just said "Check for Updates," so leaving without
                // telling the user it didn't happen would read as a dead
                // button rather than the back-compat gap it actually is.
                let fallbackAlert = NSAlert()
                fallbackAlert.messageText = "Check for Updates From Cheerio Itself"
                fallbackAlert.informativeText =
                    "The installed copy is old enough that it can't be asked automatically. In its menu bar, choose Cheerio → Check for Updates…"
                fallbackAlert.addButton(withTitle: "OK")
                fallbackAlert.runModal()
            }
        }
        exit(0)
    }

    private static func presentMoveToApplicationsPanel(currentBundleURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Move Cheerio to Applications?"
        alert.informativeText = "Cheerio can only update itself from a stable location. Move it there now?"
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")

        guard alert.runModal() == .alertFirstButtonReturn else {
            // Keep running from the current, unstable location for this
            // session. The same question comes up again next launch — this is
            // the one place that's deliberate: unlike the dev-build case,
            // there's a real fix on offer, and declining it doesn't fix
            // anything.
            return
        }

        switch MoveToApplications.perform(currentBundleURL: currentBundleURL) {
        case .success(let installedURL):
            MoveToApplications.relaunch(at: installedURL)
            exit(0)
        case .failure(let error):
            log.error("Move to Applications failed: \(error.localizedDescription, privacy: .public)")
            let failureAlert = NSAlert()
            failureAlert.messageText = "Couldn't Move Cheerio"
            failureAlert.informativeText = error.localizedDescription
            failureAlert.runModal()
        // Continue running from the current, unstable location — nothing
        // here should block the meeting the user opened the app for.
        }
    }

    private static func isQuarantined(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]) else {
            return false
        }
        return values.quarantineProperties != nil
    }

    private static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]) else { return false }
        return values.volumeIsReadOnly ?? false
    }
}
