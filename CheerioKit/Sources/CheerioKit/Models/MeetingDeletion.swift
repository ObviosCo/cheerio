import Foundation
import OSLog
import SwiftData

/// Deletes one meeting and everything only it owns.
///
/// `Meeting.segments`' `.cascade` delete rule handles the transcript automatically —
/// deleting the row is enough for that half. The other half, the recorded audio
/// directory, lives outside SwiftData entirely (see `AudioStorage`), so nothing
/// about deleting the model touches it; this is the one place that does both
/// together, so a caller can't delete the row and forget the files, or vice versa.
public enum MeetingDeletion {
    private static let log = Logger(subsystem: "app.cheerio.mac", category: "MeetingDeletion")

    /// Deletes the meeting identified by `meetingID`, in a **fresh** `ModelContext`
    /// opened on `container` — deliberately not whatever context the caller is
    /// using for everything else.
    ///
    /// Why isolated: the app's shared context is also where
    /// `CaptureSession.handle` inserts newly transcribed segments while a
    /// recording is in progress, checkpointed there on a periodic save rather
    /// than left pending until `stop()` — and deleting an *older* meeting
    /// mid-recording is allowed (`CaptureSession.canDelete(_:)` only forbids
    /// deleting the meeting actively recording). A failed save on a shared
    /// context has to roll back somehow,
    /// and `ModelContext.rollback()` discards every pending change registered on
    /// that context, not just this deletion's — so running this against the
    /// shared context could cost a live recording its not-yet-saved transcript
    /// over nothing more than this delete's own save failing. A dedicated,
    /// disposable context has nothing else pending to lose.
    ///
    /// Takes an id and refetches rather than taking a `Meeting` directly, for the
    /// same reason: a model object belongs to the context that vended it, and
    /// this needs one that belongs to its own context instead. Matched in memory
    /// rather than through a `#Predicate` on `persistentModelID` — this library
    /// is one person's meetings, so fetching all of them is cheap, and it
    /// sidesteps relying on a predicate compiler over a synthesized identity
    /// property (`ContentView.openRequestedMeeting()` makes the same call, over
    /// `uuid`, for a related reason).
    ///
    /// The model deletion is persisted *before* the audio directory is touched —
    /// the other order meant a failed save could leave the meeting alive but its
    /// audio already, irreversibly, gone. Same reasoning as
    /// `ParticipantsView.remove(_:)`'s delete-then-save-then-unlink for an
    /// enrolled speaker's sample. A failed save rolls this dedicated context back
    /// and rethrows, so both the row and the file survive to be retried.
    ///
    /// Audio removal itself stays best-effort once the save has succeeded: a
    /// failure there is logged, not thrown, because "Delete" is an explicit,
    /// already-confirmed choice — leaving the meeting behind in the library
    /// because a file on disk couldn't be removed would be more surprising than a
    /// directory `AudioOrphanSweep` will pick up and remove at the next launch.
    ///
    /// `save` and `removeAudio` default to `context.save()` and
    /// `AudioStorage.removeDirectory(atRelativePath:)`, and exist as parameters so
    /// tests can inject a failing save (to prove the audio survives it, and that
    /// nothing outside this dedicated context is disturbed) and can point audio
    /// removal somewhere other than the real Application Support container.
    public static func delete(
        meetingID: PersistentIdentifier,
        container: ModelContainer,
        save: (ModelContext) throws -> Void = { try $0.save() },
        removeAudio: (String) throws -> Void = AudioStorage.removeDirectory(atRelativePath:)
    ) throws {
        let context = ModelContext(container)
        guard
            let meeting = try context.fetch(FetchDescriptor<Meeting>())
                .first(where: { $0.persistentModelID == meetingID })
        else {
            // Already gone — a concurrent delete, most likely. Nothing left to do.
            return
        }

        let relativePath = meeting.audioDirectory
        context.delete(meeting)
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        if let relativePath {
            do {
                try removeAudio(relativePath)
            } catch {
                log.error("Couldn't remove audio at \(relativePath, privacy: .public): \(error)")
            }
        }
    }
}
