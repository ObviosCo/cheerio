import Foundation
import OSLog
import Sparkle

/// Automatic updates, via Sparkle 2, and the whole of Cheerio's network use.
///
/// Builds are distributed as a zip on GitHub Releases rather than through the App
/// Store (App Sandbox has to stay off — see `Cheerio.entitlements`), so nothing
/// updates the app unless the app does it itself. Without this, everyone who
/// downloads an early build is stranded on it.
///
/// What talks to the network, and only this:
/// - a GET of the appcast named by `SUFeedURL` in `Info.plist`, on a 24-hour
///   schedule and when the user asks;
/// - a GET of the zip that appcast points at, if the user accepts an update.
///
/// Both are Cheerio's own distribution endpoints — GitHub Pages for the feed,
/// GitHub Releases for the build. No analytics, no accounts, no profile: see
/// ``UpdatePolicy``. Recording and processing a meeting still need nothing from the
/// network, and ``UpdatePolicy`` keeps update checks out of their way.
@MainActor
@Observable
final class AppUpdater {
    /// Sparkle's standard controller: its updater, its standard user interface, and
    /// the settings below. Those settings live in Sparkle's own user defaults and are
    /// read and written through it — Cheerio keeps no second copy of "should we check
    /// for updates", so there is nothing to fall out of sync.
    @ObservationIgnored private let controller: SPUStandardUpdaterController

    /// Retained here because `SPUStandardUpdaterController` holds its delegate weakly.
    @ObservationIgnored private let policy: UpdatePolicy

    @ObservationIgnored private let log = Logger(subsystem: "app.cheerio.mac", category: "Updates")

    init(session: CaptureSession) {
        policy = UpdatePolicy(session: session)
        // `startingUpdater: false`, then started by hand, so that a misconfigured
        // build — an `SUPublicEDKey` still holding its placeholder, a feed URL that
        // isn't https — is a log line instead of the modal "contact the app
        // developer" alert `SPUStandardUpdaterController.startUpdater()` puts up on
        // its own. Updates are allowed to fail quietly. Recording is not allowed to
        // be interrupted by them failing.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: policy,
            userDriverDelegate: nil
        )
        do {
            // `start()` is Swift's name for `-startUpdater:`.
            try controller.updater.start()
        } catch {
            // Nothing else changes: the app records, transcribes and summarizes
            // exactly as before, it just won't learn about new versions.
            log.error("Updater did not start; updates are off for this launch: \(error.localizedDescription, privacy: .public)")
        }
        // Redundant with `SUEnableSystemProfiling` being false in Info.plist and with
        // ``UpdatePolicy`` returning no feed parameters. Set anyway: "no analytics" is
        // a repo invariant, and this is the property that would actually append the OS
        // version, CPU and model to the feed request if it ever drifted to true.
        controller.updater.sendsSystemProfile = false
    }

    /// The "Check for Updates…" action. Sparkle reports back verbosely — including
    /// "you're up to date" and any network failure — because the user asked.
    ///
    /// Safe to call at any time: if an update is already being shown, Sparkle brings
    /// that window into focus instead of starting a second check.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Whether Sparkle checks on its own schedule (every 24 hours). On by default via
    /// `SUEnableAutomaticChecks`.
    ///
    /// Backed by Sparkle's user defaults, not by ours. `access`/`withMutation` are the
    /// Observation registrar's hooks for exactly this — a computed property over
    /// storage the macro can't see, which SwiftUI still has to be told about.
    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.checksAutomatically) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// Whether an update, once found, installs itself without being asked. Off by
    /// default via `SUAutomaticallyUpdate`: an app you leave running through meetings
    /// is the wrong place for a surprise replacement.
    var downloadsAutomatically: Bool {
        get {
            access(keyPath: \.downloadsAutomatically)
            return controller.updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.downloadsAutomatically) {
                controller.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }
}

/// Sparkle's updater delegate. Two jobs, both of them refusals.
@MainActor
final class UpdatePolicy: NSObject, SPUUpdaterDelegate {
    /// Read to answer one question: is a meeting being recorded right now.
    private let session: CaptureSession

    init(session: CaptureSession) {
        self.session = session
        super.init()
    }

    /// Gates the *start* of every update check — scheduled or user-initiated — away
    /// from an active recording.
    ///
    /// Left alone, Sparkle's 24-hour timer will fire whenever it likes, and "whenever
    /// it likes" includes the middle of a call: it would put an update window in front
    /// of the meeting you are in, and with automatic installs turned on it would stage
    /// a replacement app under a process that is writing audio to disk.
    ///
    /// Every check is refused while `session.state != .idle`, including `.updates` —
    /// the user having just picked "Check for Updates…". Sparkle surfaces this
    /// method's thrown error as the check's result, so a manual check mid-meeting
    /// shows the user `UpdateDeferral.recordingInProgress`'s message instead of
    /// silently doing nothing; that's the right UX for a check the user asked for.
    ///
    /// Honest about what this does and doesn't cover: it's a start-time gate only. A
    /// check (or a download) already admitted while idle is not aborted if a recording
    /// starts partway through it. That's a documented edge, not machinery — there is
    /// deliberately no mechanism to cancel work in flight.
    ///
    /// Also honest about what refusing costs a *background* check: Sparkle treats this
    /// as a deferral, not a shutdown — it reschedules — but it also records the
    /// attempt as the last check, so a check vetoed mid-meeting is retried on the next
    /// interval (about a day later) rather than as soon as the meeting ends. That is
    /// the whole of the behavior; there is deliberately no catch-up machinery.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard session.state == .idle else {
            throw UpdateDeferral.recordingInProgress
        }
    }

    /// No query parameters on the feed request, ever — not even when Sparkle thinks it
    /// is allowed to send a profile. This is the method that would carry them.
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        []
    }

    /// And nothing allowed through if some future change did enable profiling.
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }
}

/// Why a scheduled update check was turned away. Surfaced only in Sparkle's log —
/// a background check has no UI, which is the point.
enum UpdateDeferral: LocalizedError {
    case recordingInProgress

    var errorDescription: String? {
        switch self {
        case .recordingInProgress:
            // No promise of an automatic retry: a vetoed scheduled check waits out
            // Sparkle's next interval, and a manual one is the user's to repeat.
            // "Busy with", not "recording" — the veto also covers `.finishing`.
            "Cheerio is busy with a meeting. Check for updates again once it finishes."
        }
    }
}
