import AppKit
import CheerioKit
import Foundation
import SwiftUI

/// Launch-time hooks the screenshot harness (`Scripts/screenshots/`) uses to put the
/// app into a photographable state.
///
/// Every value here is read from `UserDefaults`, and the harness passes them as
/// launch arguments — the *argument* domain, which is read-only and evaporates when
/// the process exits, so nothing here can be left switched on by accident and none
/// of it is written to anyone's preferences. Absent argument, absent behaviour: each
/// property returns nil and its call site does nothing.
///
/// Why this exists rather than a script clicking the real UI: synthesizing a click
/// (`CGEventPost`, AppleScript's System Events, `cliclick`) requires the *automating*
/// process to hold macOS Accessibility permission, and XCUITest requires developer
/// mode. A harness that depends on either is a harness that can't run on a fresh
/// machine or a CI runner without someone granting it permissions by hand first.
/// These hooks reach the same states with no input at all, which also makes the
/// captures deterministic — no waiting for a click to land, no window that moved.
///
/// They are hooks into *presentation only*: which window opens, how big it is,
/// which row starts selected, and — where a screen derives a number from the clock
/// rather than from the store — what that number reads as. Nothing here can record,
/// grant a permission, or write to the store, and none of it is reachable without
/// passing the argument.
enum ScreenshotMode {
    /// The library window's `NSWindow.identifier`, which SwiftUI sets from the scene
    /// id — windows are matched on that rather than on `frameAutosaveName`, which
    /// SwiftUI leaves empty on its scene windows.
    ///
    /// Spelled out rather than referencing `MenuBarView.mainWindowID`, which is
    /// main-actor isolated and so can't initialize a nonisolated constant. Same for
    /// the walkthrough's `OnboardingView.windowID` below.
    private static let mainWindowIdentifier = "main"
    private static let onboardingWindowIdentifier = "onboarding"

    /// Which meeting the library should open with selected, as a 1-based index into
    /// the sidebar's order (newest first). Absent means "select nothing", which is
    /// the normal launch behaviour.
    static var selectedMeetingIndex: Int? {
        value(forKey: "screenshotSelectMeeting").map { UserDefaults.standard.integer(forKey: $0) }
            .flatMap { $0 > 0 ? $0 - 1 : nil }
    }

    /// Opens Settings once the main window is up.
    static var opensSettings: Bool {
        UserDefaults.standard.bool(forKey: "screenshotOpenSettings")
    }

    /// Closes the library window after ``opensSettings`` has done its work.
    ///
    /// Exists for the Settings *audits* (`CheerioAccessibilityTests`), not the
    /// screenshots: `performAccessibilityAudit` walks every window the app has, and
    /// on a CI runner's 1024×768 screen the Settings window always overlaps the
    /// library behind it — so auditing "Settings" also samples library elements
    /// through the Settings window's pixels, producing contrast findings about
    /// text that isn't visible at all. Screenshots don't have this problem (they
    /// photograph one window by title) and keep the library open for depth.
    static var closesMainWindow: Bool {
        UserDefaults.standard.bool(forKey: "screenshotCloseMainWindow")
    }

    /// Which onboarding step the walkthrough starts on, as a
    /// `OnboardingCoordinator.Step` raw value. Absent means the first one, which is
    /// what a real first run does.
    static var onboardingStep: Int? {
        value(forKey: "screenshotOnboardingStep").map { UserDefaults.standard.integer(forKey: $0) }
    }

    /// Forces the meeting detail view's transcript disclosure open at launch.
    ///
    /// A real launch always starts collapsed (#104) — this exists only for the
    /// `library-transcript` capture, whose entire point is showing transcript
    /// lines under the notes. Same shape as the other hooks here: an argument the
    /// harness passes rather than a simulated click on the disclosure triangle.
    static var expandsTranscript: Bool {
        UserDefaults.standard.bool(forKey: "screenshotExpandTranscript")
    }

    /// Presents the speakers panel's "Use as voice sample" sheet
    /// (`EnrollFromMeetingSheet`) for the selected meeting's first speaker.
    ///
    /// The sheet is otherwise only reachable through a row's ellipsis menu, which
    /// neither harness clicks — without this the accessibility audits (#142)
    /// could never measure its text. Same shape as every other hook here: it
    /// pre-sets presentation state, it doesn't save a sample or touch the store.
    static var showsEnrollFromMeetingSheet: Bool {
        UserDefaults.standard.bool(forKey: "screenshotEnrollFromMeetingSheet")
    }

    /// Shows `VoiceEnrollmentRecorder`'s post-save acknowledgment (issue #128)
    /// instead of its empty form.
    ///
    /// Nothing else in this harness can reach that state: every other hook here
    /// opens to a screen a launch argument can select, but a saved sample only
    /// exists after 30 seconds of real audio and a write to the store, and
    /// "Permissions and recordings" above is explicit that this harness presses
    /// no button that starts one. Without this the walkthrough's voice-enrollment
    /// capture could only ever show the empty form, never the confirmation the
    /// issue added.
    static var showsVoiceEnrollmentConfirmation: Bool {
        UserDefaults.standard.bool(forKey: "screenshotVoiceEnrollmentConfirmed")
    }

    /// The empty-state dashboard's activity numbers, as
    /// "meetings,minutes,followUps". Absent computes them from the store, which is
    /// what a real launch does.
    ///
    /// Exists because those numbers are read off the *runner's clock*, not just the
    /// store: `meetingsThisWeek` counts seeded meetings inside whichever calendar
    /// week the machine is in, and the demo store's meetings sit at fixed offsets
    /// from launch — so the digit rendered here changes as the real week rolls over
    /// and took the accessibility audit's verdict with it (#184, green on a Thursday
    /// and red on the Friday, with no UI change in between). A gate whose answer
    /// depends on the date isn't one. Same benefit for the screenshots, which
    /// photograph this screen for the site and shouldn't publish a different number
    /// each release.
    ///
    /// Presentation only, like everything else here: this supplies digits to draw.
    /// It doesn't write the store, and nothing downstream of the dashboard reads it.
    static var activityStats: MeetingActivityStats? {
        guard let raw = UserDefaults.standard.string(forKey: "screenshotActivityStats") else { return nil }
        let parts = raw.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return MeetingActivityStats(
            meetingsThisWeek: parts[0],
            minutesTranscribedThisWeek: parts[1],
            openFollowUps: parts[2]
        )
    }

    /// Which of the dashboard's rotating tips it shows, as a seed for
    /// `DashboardTip.forLaunch(seed:)` — the same entry point the app itself uses,
    /// so the mapping from a number to a tip lives in one place. Absent rotates
    /// per launch, which is the real behaviour.
    ///
    /// The other half of the dashboard's non-determinism: the tip is seeded from
    /// `systemUptime`, so consecutive runs of either harness photograph and audit
    /// different sentences.
    static var dashboardTip: DashboardTip? {
        value(forKey: "screenshotDashboardTip")
            .map { DashboardTip.forLaunch(seed: UserDefaults.standard.integer(forKey: $0)) }
    }

    /// Which appearance the whole app renders in — "light" or "dark" — overriding
    /// the system setting for this launch only. Absent follows the system, which is
    /// what a real launch does.
    ///
    /// Exists for the accessibility audits (`CheerioAccessibilityTests`), which have
    /// to check contrast under both appearances no matter what the machine running
    /// them is set to — a dark-on-dark mistake like #141 is invisible to an audit
    /// that only ever sees light mode. `NSApplication.appearance` rather than a
    /// per-window override, because the audits also cover Settings and the
    /// walkthrough, which are separate windows.
    static var appearance: NSAppearance? {
        switch UserDefaults.standard.string(forKey: "screenshotAppearance") {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    /// Applies ``appearance``. Called from `CheerioApp.init()` rather than
    /// ``applyAtLaunch(openWindow:)``, which only runs once the *library* renders —
    /// a first-run launch (the walkthrough audits) never gets there.
    @MainActor static func applyAppearanceOverride() {
        guard let appearance else { return }
        NSApplication.shared.appearance = appearance
    }

    /// The main window's size in points, as "1440x900". Absent leaves the window
    /// wherever macOS put it.
    static var windowSize: CGSize? {
        guard let raw = UserDefaults.standard.string(forKey: "screenshotWindowSize") else { return nil }
        let parts = raw.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    /// Applies the hooks that need a window to exist. Called from the library
    /// window's `.task`, which is the first moment that's true.
    ///
    /// - Parameter openWindow: the environment's window opener, which only a view can
    ///   supply — the walkthrough is a `Window` scene and AppKit has no handle on it.
    @MainActor static func applyAtLaunch(openWindow: OpenWindowAction) async {
        guard windowSize != nil || opensSettings || onboardingStep != nil else { return }
        // macOS restores the window's remembered frame after the first render, so a
        // resize applied synchronously here is undone a moment later. Nothing
        // observable says when that has happened, hence a wait rather than a check.
        try? await Task.sleep(for: .milliseconds(700))
        // An app brings itself forward far more reliably than another process can
        // bring it forward, and the capture depends on it: a window that isn't
        // frontmost is, with Stage Manager on, a thumbnail in the side strip, and
        // that thumbnail is what `screencapture` hands back.
        NSApplication.shared.activate()
        resizeMainWindow()
        if opensSettings { openSettings() }
        // Opened explicitly rather than left to `defaultLaunchBehavior`, which decides
        // whether the walkthrough claims launch on a first run — a decision the
        // harness has no way to reproduce without also being a first run.
        if onboardingStep != nil { openWindow(id: onboardingWindowIdentifier) }
        guard opensSettings || onboardingStep != nil else { return }
        try? await Task.sleep(for: .milliseconds(400))
        makeSecondaryWindowKey()
        // Only after the secondary window exists and is key — closing the last
        // visible window first would leave nothing on screen for a moment, and
        // the app quits nothing here (the menu bar scene keeps it alive).
        if closesMainWindow { closeMainWindow() }
    }

    @MainActor private static func closeMainWindow() {
        for window in NSApplication.shared.windows
        where window.identifier?.rawValue == mainWindowIdentifier {
            window.close()
        }
    }

    /// Brings whichever window was just opened to the front and makes it key.
    ///
    /// Without this the capture is a coin toss between an active and an inactive
    /// window: macOS dims a window's title, its controls and its selection when it
    /// isn't key, so two runs of the harness produced two visibly different pictures
    /// of the same screen. Ordering a window front from *inside* the app needs no
    /// Accessibility permission — it's the automating process that would need it.
    @MainActor private static func makeSecondaryWindowKey() {
        let window = NSApplication.shared.windows.first {
            $0.isVisible && $0.styleMask.contains(.titled)
                && $0.identifier?.rawValue != mainWindowIdentifier
        }
        window?.makeKeyAndOrderFront(nil)
    }

    @MainActor private static func resizeMainWindow() {
        guard let windowSize else { return }
        for window in NSApplication.shared.windows
        where window.identifier?.rawValue == mainWindowIdentifier {
            window.setFrame(
                CGRect(origin: window.frame.origin, size: windowSize),
                display: true
            )
            window.center()
        }
    }

    /// Opens Settings by performing the app menu's own "Settings…" item.
    ///
    /// SwiftUI vends no programmatic way in: `SettingsLink` is a view, and
    /// `openWindow` doesn't accept the settings scene. Sending the documented
    /// `showSettingsWindow:` selector down the responder chain doesn't work either —
    /// it returns false on macOS 26, as does its pre-Ventura spelling
    /// `showPreferencesWindow:`. The menu item is the one handle that's definitely
    /// wired to whatever SwiftUI is using, so this finds it and performs it.
    @MainActor private static func openSettings() {
        guard let appMenu = NSApplication.shared.mainMenu?.items.first?.submenu else { return }
        // Ventura renamed Preferences to Settings; the app menu is small enough to
        // just look at both.
        guard
            let index = appMenu.items.firstIndex(where: {
                $0.title.hasPrefix("Settings") || $0.title.hasPrefix("Preferences")
            })
        else { return }
        appMenu.performActionForItem(at: index)
    }

    /// Distinguishes "argument not passed" from "passed as 0", which `integer(forKey:)`
    /// alone can't. Returns the key back so the caller can read it in the type it wants.
    private static func value(forKey key: String) -> String? {
        UserDefaults.standard.object(forKey: key) == nil ? nil : key
    }
}
