import AppKit
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
/// These four hooks reach the same states with no input at all, which also makes the
/// captures deterministic — no waiting for a click to land, no window that moved.
///
/// They are hooks into *presentation only*: which window opens, how big it is, and
/// which row starts selected. Nothing here can record, grant a permission, or write
/// to the store, and none of it is reachable without passing the argument.
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
