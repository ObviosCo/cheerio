import CheerioKit
import SwiftData
import SwiftUI

/// The permission-check-then-`CaptureSession.start` sequence behind every
/// window-based "Start recording"/"Give Direction…" button — the sidebar's own
/// controls (``MeetingListView``) and, since #124, the empty-state dashboard's.
/// Factored out so a second surface offering the same two actions calls this instead
/// of a second copy of the same `Task` and error handling.
///
/// `MenuBarView.start(event:kind:)` is deliberately not folded in here: a menu can't
/// present an alert, so on failure it always falls back to bringing the main window
/// forward, instead of setting `session.startFailure` and relying on an `.alert`
/// modifier the way both of the callers above do.
@MainActor
enum RecordingStartFlow {
    /// - Parameter selection: cleared before the attempt so a past meeting on screen
    ///   doesn't keep covering the detail column while the new one spins up.
    static func start(
        kind: MeetingKind,
        event: CalendarMeeting? = nil,
        session: CaptureSession,
        context: ModelContext,
        selection: Binding<Meeting?>
    ) {
        Task {
            guard await MicrophoneCapture.permission() == .granted else {
                // Re-asking can't help once it's been denied, so offer the only
                // thing that can fix it.
                session.startFailure = .microphoneDenied
                return
            }
            selection.wrappedValue = nil
            do {
                try await session.start(
                    // Same placeholder wording regardless of which control started
                    // it — see `MenuBarView.autoTitle(for:)`.
                    title: event?.title ?? MenuBarView.autoTitle(for: kind),
                    calendarEventID: event?.id,
                    calendarEventOccurrenceStart: event?.startDate,
                    kind: kind,
                    context: context
                )
            } catch {
                session.startFailure = .failed(error.localizedDescription)
            }
        }
    }
}
