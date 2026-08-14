import CheerioKit
import SwiftData
import SwiftUI

/// Live view during a meeting: transcript on the left, rough-notes
/// scratchpad on the right (the Granola pattern).
///
/// What it draws is ``RecordingSurface``; what it owns is the session. The split
/// is #164: an accessibility audit can reach a view that takes values, and can
/// never reach one that requires two capture channels to be running. Everything
/// left here needs the session or the store — the bindings that write back
/// through `CaptureSession`, the hold-activity observers, and the enrollment
/// nudge's once-ever bookkeeping.
struct RecordingView: View {
    @Environment(CaptureSession.self) private var session
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<EnrolledSpeaker> { $0.isMe }) private var enrolledMe: [EnrolledSpeaker]

    /// Encourage-not-block, per the onboarding walkthrough: shown at most once ever
    /// (``OnboardingState/hasShownEnrollmentNudge``), and never stands between
    /// pressing "record" and the recording actually starting.
    @State private var showEnrollmentNudge = false
    @State private var showEnrollmentSheet = false

    var body: some View {
        @Bindable var session = session

        RecordingSurface(
            state: session.state,
            meeting: session.meeting,
            processingPhaseLabel: session.currentMeetingProcessingPhase?.label,
            startedAt: session.startedAt,
            liveLines: session.liveLines,
            volatileLine: session.volatileLine,
            holdDeadline: session.holdDeadline,
            showsEnrollmentNudge: showEnrollmentNudge,
            roughNotes: $session.roughNotes,
            // The `hold*` accessors, not the meeting's fields directly, so every
            // edit also counts as holding activity — see `CaptureSession.holdKind`.
            holdKind: $session.holdKind,
            holdRunsCallback: $session.holdRunsCallback,
            holdTriggerID: $session.holdTriggerID,
            holdCallbackPrompt: $session.holdCallbackPrompt,
            onProcessNow: { Task { await session.confirmProcessing(context: context) } },
            onStop: { Task { await session.stop(context: context) } },
            onTitleSubmit: { try? context.save() },
            onAddVoice: { showEnrollmentSheet = true },
            onDismissEnrollmentNudge: { showEnrollmentNudge = false }
        )
        // Every edit surface this view keeps live through `.holding` counts as
        // holding activity — the scratchpad, the title field, and the participant
        // roster all restart the grace window, or auto-processing could cut off a
        // rename mid-word and ship the callback a partial title. All no-ops
        // outside `.holding` (the session guards), so none need their own state
        // check. The kind picker and callback controls don't need observers here:
        // they already route through the session's `hold*` accessors, which record
        // activity themselves.
        .onChange(of: session.roughNotes) {
            session.recordHoldActivity()
        }
        .onChange(of: session.meeting?.title) {
            session.recordHoldActivity()
        }
        .onChange(of: session.meeting?.participantNames) {
            session.recordHoldActivity()
        }
        .onAppear {
            // Only ever the first recording after a skipped enrollment — this view
            // reappears on every recording, but the persisted flag keeps it quiet
            // after the first showing.
            guard enrolledMe.isEmpty, !OnboardingState.hasShownEnrollmentNudge else { return }
            OnboardingState.hasShownEnrollmentNudge = true
            showEnrollmentNudge = true
        }
        .sheet(isPresented: $showEnrollmentSheet) {
            VoiceEnrollmentSheet {
                // A successful enrollment resolves the reason the banner is up in
                // the first place — leave it showing and it reads as a bug: "I just
                // did what it asked, why is it still there?"
                showEnrollmentNudge = false
            }
        }
    }
}
