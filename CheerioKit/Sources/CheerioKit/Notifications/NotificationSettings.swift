import Foundation

/// The two desktop notifications from issue #51, and whether the user wants them.
///
/// Following ``TranscriptCallbackScope``'s pattern: the value lives directly in
/// `UserDefaults` so Settings can bind it with `@AppStorage`, and the accessors here
/// give non-view code the same answer without a second copy of the key or the
/// default.
///
/// This is only "has the user asked for this". Whether macOS will actually deliver
/// anything is a separate question — the system authorization is checked at the
/// moment of posting, in the app target's `NotificationService`, because a
/// preference and a permission fail differently: a preference turned off means
/// don't ask, and a permission denied means degrade silently.
public enum NotificationSettings {
    public static let suggestRecordingKey = "notifySuggestRecording"
    public static let notesReadyKey = "notifyNotesReady"

    /// Offer to record when a calendar meeting starts.
    public static var suggestsRecording: Bool { isEnabled(suggestRecordingKey) }

    /// Say so when a finished recording has been transcribed and summarized.
    public static var announcesNotesReady: Bool { isEnabled(notesReadyKey) }

    /// Both default on, which is why this can't be `UserDefaults.bool(forKey:)` —
    /// that reads an absent key as `false`, i.e. as "the user turned this off",
    /// which is the opposite of never having been asked. The `object(forKey:)`
    /// round trip is what distinguishes unset from set-to-false, and it matches
    /// what `@AppStorage(key) var x = true` does on the Settings side.
    private static func isEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
