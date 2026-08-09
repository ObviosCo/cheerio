import Foundation

/// Whether the first-run walkthrough has run, and whether the one-time "add your
/// voice" nudge at the first recording has already been shown.
///
/// Both are plain `UserDefaults` flags rather than SwiftData — portable to
/// CheerioKit's future iOS target the same way ``AudioRetention`` is, and readable
/// without a `ModelContext` (which `hasShownEnrollmentNudge` needs from inside a
/// recording, well after the container exists anyway).
///
/// `hasCompleted` specifically drives which window a first run actually shows
/// (#63): both of `CheerioApp`'s windows now have fixed, unconditional launch
/// behavior — the library window `.automatic`, the walkthrough `.suppressed` — so
/// this flag no longer has to be readable before the container opens to pick a
/// scene at launch. Instead `ContentView.body` reads it, every time `body` runs,
/// to decide whether to render the library or hand off — worth calling out because
/// this value is a plain `UserDefaults` flag, not something SwiftUI can observe, so
/// *where* it's read is what decides whether a rebuild sees a stale answer. Only the
/// handoff itself — opening the walkthrough and dismissing this window — runs in
/// `onAppear`, once `body` has already decided it's needed. `OnboardingView.onDisappear`
/// sets the flag true and hands the library window back once the walkthrough finishes.
public enum OnboardingState {
    public static let hasCompletedKey = "onboardingHasCompleted"
    public static let hasShownEnrollmentNudgeKey = "onboardingHasShownEnrollmentNudge"

    /// True once the walkthrough has been finished, skipped, or simply closed.
    /// There's no separate "skipped" state to track — every exit from the
    /// walkthrough means "don't show this automatically again," and it stays
    /// re-openable from Settings/Help regardless of how it ended.
    public static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: hasCompletedKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasCompletedKey) }
    }

    /// Whether the encourage-not-block nudge to enroll a voice has already been
    /// shown at the start of a recording. Shown at most once ever — nagging on
    /// every meeting would be worse than the "Speaker 2" labels it's fixing.
    public static var hasShownEnrollmentNudge: Bool {
        get { UserDefaults.standard.bool(forKey: hasShownEnrollmentNudgeKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasShownEnrollmentNudgeKey) }
    }
}
