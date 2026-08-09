import Foundation

/// Shared confirmation copy for deleting a meeting. Both Delete affordances — the
/// library list's context menu and the detail view's toolbar — read from here, so
/// the wording can't drift between the two places someone encounters it.
enum DeleteMeetingConfirmation {
    static func title(for meetingTitle: String) -> String {
        "Delete “\(meetingTitle)”?"
    }

    static let message =
        "This removes its transcript, notes, and any retained audio. This can't be undone."
}
