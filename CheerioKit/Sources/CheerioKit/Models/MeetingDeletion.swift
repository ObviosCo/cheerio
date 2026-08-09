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

    /// Deletes `meeting` and saves `context`.
    ///
    /// `removeAudio` defaults to `AudioStorage.removeDirectory(atRelativePath:)` and
    /// exists as a parameter so tests can point it somewhere other than the real
    /// Application Support container. Audio removal is best-effort: a failure is
    /// logged, not thrown, because "Delete" is an explicit, already-confirmed
    /// choice — leaving the meeting behind in the library because a file on disk
    /// couldn't be removed would be more surprising than a stray directory under
    /// the app's container that a later run can still clean up.
    public static func delete(
        _ meeting: Meeting,
        context: ModelContext,
        removeAudio: (String) throws -> Void = AudioStorage.removeDirectory(atRelativePath:)
    ) throws {
        if let relativePath = meeting.audioDirectory {
            do {
                try removeAudio(relativePath)
            } catch {
                log.error("Couldn't remove audio at \(relativePath, privacy: .public): \(error)")
            }
        }
        context.delete(meeting)
        try context.save()
    }
}
