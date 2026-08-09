import CheerioKit
import SwiftData

/// The "Convert to Directive"/"Convert to Meeting" write (issue #107) — one shared
/// function for `MeetingListView`'s row context menu and `MeetingDetailView`'s
/// toolbar button, so the two entry points can't diverge the way they briefly did:
/// Copilot's review on #115 caught the toolbar button routing through
/// `MeetingDetailView`'s general-purpose `save()`, which also resolves speaker
/// slots and reconciles action items and reports any failure as "Couldn't identify
/// speakers" — unrelated work, and the wrong error message, for a plain kind flip.
/// `Meeting.toggleKind()` documents "mechanical only, nothing else" as the whole
/// point of conversion; a shared save is what keeps that true at both call sites
/// instead of just the one whoever touches it last remembers to write carefully.
///
/// Rollback-complete the same way `MeetingSpeakersSection`'s enroll/confirm and
/// `RenameMeetingAlert` already are (#99): a failed save must put the model back to
/// what it was, or a later autosave silently persists a flip the person was just
/// told had failed. Captures `kindRaw` rather than `kind` before flipping — the raw
/// string is what a save actually persists, and restoring it directly needs no
/// second trip through the `kind` setter to undo.
///
/// Returns an error message for the caller's own alert, or nil on success. Each
/// call site keeps its own `@State` error rather than sharing one, the same way
/// `deleteError` is never shared between the two Delete affordances — a caller-owned
/// alert is what lets this stay a plain function instead of a view modifier with
/// nothing to attach to.
@discardableResult
func convertMeetingKind(_ meeting: Meeting, context: ModelContext) -> String? {
    let priorKindRaw = meeting.kindRaw
    meeting.toggleKind()
    do {
        try context.save()
        return nil
    } catch {
        meeting.kindRaw = priorKindRaw
        return error.localizedDescription
    }
}
