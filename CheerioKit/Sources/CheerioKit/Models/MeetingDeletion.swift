import Foundation
import OSLog
import SwiftData

/// Deletes one meeting and everything only it owns.
///
/// `Meeting.segments`' `.cascade` delete rule handles the transcript automatically —
/// `context.delete(meeting)` is enough for that half. The other half, the recorded
/// audio directory, lives outside SwiftData entirely (see `AudioStorage`), so
/// nothing about deleting the model touches it; this is the one place that does
/// both together, so a caller can't delete the row and forget the files, or vice
/// versa.
public enum MeetingDeletion {
    private static let log = Logger(subsystem: "app.cheerio.mac", category: "MeetingDeletion")

    /// Deletes `meeting` and saves `context`, then best-effort removes its audio
    /// directory.
    ///
    /// The model deletion is persisted *before* the audio file is touched — the
    /// other order meant a failed save could leave the meeting alive but its
    /// audio already, irreversibly, gone. Same reasoning as
    /// `ParticipantsView.remove(_:)`'s delete-then-save-then-unlink for an enrolled
    /// speaker's sample. A failed save rolls the context back, so it can't leave a
    /// half-deleted meeting behind either.
    ///
    /// `save` and `removeAudio` default to `context.save()` and
    /// `AudioStorage.removeDirectory(atRelativePath:)`, and exist as parameters so
    /// tests can inject a failing save (to prove the audio survives it) and can
    /// point audio removal somewhere other than the real Application Support
    /// container. Audio removal itself is still best-effort once the save has
    /// succeeded: that failure is logged, not thrown, because "Delete" is an
    /// explicit, already-confirmed choice — leaving the meeting behind in the
    /// library because a file on disk couldn't be removed would be more
    /// surprising than a stray directory under the app's container that a later
    /// run can still clean up.
    public static func delete(
        _ meeting: Meeting,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() },
        removeAudio: (String) throws -> Void = AudioStorage.removeDirectory(atRelativePath:)
    ) throws {
        // Snapshotted before the delete: `meeting` is unusable once `save` below
        // commits it.
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
