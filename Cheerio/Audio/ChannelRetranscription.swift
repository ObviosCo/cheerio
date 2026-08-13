import CheerioKit
import Foundation
import OSLog
import SwiftData

/// Re-transcribes one channel of a finished meeting from its retained audio, and
/// leaves the meeting in the state the recording pipeline would have left it in
/// (issue #14).
///
/// The app-target half of the repair, in the same relationship to
/// `TranscriptRepair` and `AudioFileTranscription` that `SpeakerLabeling` has to
/// `SpeakerAttributionService`: CheerioKit owns the transcription and the merge
/// rule, this owns the sequencing, the processing mark, and what the store looks
/// like afterward.
///
/// Sequenced, not reimplemented: fresh lines have to go through the same
/// bleed-marking and diarization the live pipeline runs, because they arrive with
/// exactly the same problems (a mic line that's really the far end through the
/// speakers, and a channel with no speaker labels at all).
@MainActor
enum ChannelRetranscription {
    private static let log = Logger(subsystem: "co.obvios.cheerio.mac", category: "ChannelRetranscription")

    /// Whether the affordance can run right now. A recording anywhere counts, not
    /// just on this meeting — see `TranscriptRepair.audioFile(for:in:isBusy:)` for
    /// why a third transcription engine must not compete with a live one.
    static func isBusy(_ meeting: Meeting, session: CaptureSession) -> Bool {
        session.state != .idle || session.isProcessing(meeting)
    }

    /// Transcribes `channel` again and merges the result. Throws only when the pass
    /// couldn't run or couldn't be saved — a failed diarization afterward leaves the
    /// recovered transcript in place with channel labels, exactly as a failed pass
    /// during a recording does.
    static func run(
        channel: SpeakerChannel,
        meeting: Meeting,
        session: CaptureSession,
        context: ModelContext
    ) async throws -> TranscriptRepair.Outcome {
        // Resolved before the mark, or this pass's own mark would read as the
        // meeting being busy.
        let audioFile = try TranscriptRepair.audioFile(
            for: channel,
            in: meeting,
            isBusy: isBusy(meeting, session: session)
        )

        // Before the first await, and cleared in a `defer` that runs on the throw
        // path too: the mark is what keeps a retention purge from deleting the CAF
        // being read, keeps the delete affordances honest, keeps a second pass from
        // starting, and keeps Sparkle out of the way while this runs.
        session.beginProcessing(meeting, phase: .transcribing)
        defer { session.endProcessing(meeting) }

        let lines = try await AudioFileTranscription.transcribe(audioFile: audioFile, channel: channel)
        let outcome = try TranscriptRepair.replace(
            channel: channel, in: meeting, with: lines, context: context)
        log.notice(
            """
            Repaired the \(channel.rawValue, privacy: .public) channel: \
            \(outcome.inserted, privacy: .public) lines in, \
            \(outcome.replaced, privacy: .public) replaced, \
            \(outcome.kept, privacy: .public) kept, \
            \(outcome.skipped, privacy: .public) skipped
            """
        )

        // The same order the recording pipeline uses, for the same reasons: bleed
        // first (a fresh mic line can be the far end heard through the speakers,
        // and nothing downstream should label or read it), then diarization over
        // lines that currently have no speaker at all.
        meeting.markBleedSegments()
        session.reportPhase(.identifyingSpeakers, for: meeting)
        do {
            try await SpeakerLabeling.label(meeting: meeting, context: context)
        } catch {
            // Best-effort, as in `CaptureSession.process`: the recovered transcript
            // keeps its Me/Them labels, which is more than it had a minute ago.
            log.error("Speaker attribution after re-transcription failed: \(error)")
        }
        let ownerNames = SpeakerLabeling.ownerNames(context: context)
        meeting.resolveSpeakerSlots(ownerNames: ownerNames)
        // A channel's lines changing wholesale invalidates who was attributed what,
        // the same trust-state invalidation a fresh diarization pass or a hand
        // correction causes — see `Meeting.reconcileActionItems`.
        meeting.reconcileActionItems(ownerNames: ownerNames)
        try context.save()
        return outcome
    }
}
