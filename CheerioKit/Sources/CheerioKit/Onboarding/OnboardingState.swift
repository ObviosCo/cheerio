import Foundation

/// Whether the first-run walkthrough has run, and whether the one-time "add your
/// voice" nudge at the first recording has already been shown.
///
/// Both are plain `UserDefaults` flags rather than SwiftData, so they're readable
/// before the model container even opens (the app-launch scene selection in
/// `CheerioApp` needs an answer before there's a `ModelContext` to ask), and
/// portable to CheerioKit's future iOS target the same way ``AudioRetention`` is.
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
