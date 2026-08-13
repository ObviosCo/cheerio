import AVFoundation
import Foundation
import OSLog

/// Transcribes a retained recording from disk, through the same
/// ``TranscriptionEngine`` a live channel runs on.
///
/// Issue #14's engine room. A meeting whose transcript came out empty or one-sided
/// can only be repaired from the CAF that survived it, and the repair has to go
/// through the live path rather than beside it: `AnalyzerAudioConverter` is what
/// makes an unusual capture format transcribable at all (issue #174 — a 3 ch /
/// 24 kHz mic whose audio the converter's default channel map silently mapped to
/// nothing), and a second, separately-maintained file path would be free to
/// regress that fix on its own. So this owns exactly one thing the live path
/// doesn't: where the audio comes from. How it gets in — the analyzer pulling one
/// window at a time, rather than a reader pushing into a queue that can't refuse —
/// belongs to `TranscriptionEngine.transcribe(file:)`, which is where the buffers
/// and the conversion already live.
///
/// What it deliberately doesn't own: what to *do* with the result. Merging lines
/// into a meeting is `TranscriptRepair`'s decision, because it turns on human
/// corrections that have nothing to do with audio.
public enum AudioFileTranscription {
    private static let log = Logger(subsystem: "co.obvios.cheerio.mac", category: "AudioFileTranscription")

    /// Reads `audioFile` end to end and returns every line the transcriber
    /// finalized, in the order it finalized them.
    ///
    /// Times are seconds from the start of the file, which is the same axis a live
    /// segment's `startTime` is on: each channel's CAF opens when that channel's
    /// capture starts, and the analyzer's clock starts at its first buffer either
    /// way. (The two differ by however long the recorder took to open the file
    /// after the engine started — tens of milliseconds, well inside the tolerance
    /// anything reading these timestamps already has.)
    ///
    /// Volatile results are dropped: they exist to animate a live transcript, and
    /// there's nothing live here.
    ///
    /// `ensureModel` is called for the same reason, and at the same point, that the
    /// live path calls it (`CaptureSession.startCapturing`, before capture starts).
    /// It is not a network dependency: a meeting that transcribed at all has the
    /// locale's asset installed already, so this returns having asked for nothing. A
    /// locale that was never installed is the one case where it would install one,
    /// which is the setup-time download CLAUDE.md's network invariant explicitly
    /// allows ("a one-time download at install/setup … would also be acceptable; a
    /// network dependency during capture never is"). What the invariant forbids is
    /// *needing* the network to record or process a meeting, and nothing here does.
    public static func transcribe(
        audioFile: URL,
        channel: SpeakerChannel,
        locale: Locale = .current
    ) async throws -> [TranscriptionUpdate] {
        // Opened here, and handed to the engine: a path that isn't a readable audio
        // file fails before a `SpeechAnalyzer` is ever built, and the duration for
        // the log below is read while this side still owns the handle. After the
        // `sending` handoff the file belongs to the engine, which is what keeps two
        // positions from being advanced against one handle.
        let file = try AVAudioFile(forReading: audioFile)
        let seconds = Int(file.durationSeconds)
        try await TranscriptionEngine.ensureModel(for: locale)

        let engine = TranscriptionEngine(channel: channel, locale: locale)
        // Attached before the pass starts: the engine's result stream is live from
        // its first setup, and a consumer attached later would miss whatever
        // finalized in between.
        let lines = Task {
            var collected: [TranscriptionUpdate] = []
            for await update in engine.results where update.isFinal {
                collected.append(update)
            }
            return collected
        }

        var passError: Error?
        do {
            try await engine.transcribe(file: file)
        } catch {
            passError = error
        }

        // Stopped on both paths, and awaited either way: `stop()` finalizes the
        // analyzer and ends the result stream, so it's also what lets the
        // collector above finish. Skipping it after a failed pass would leave
        // that task — and the analyzer it holds — running for the life of the
        // process.
        var stopError: Error?
        do {
            try await engine.stop()
        } catch {
            stopError = error
        }
        let collected = await lines.value

        if let error = passError ?? stopError {
            log.error(
                "Re-transcribing the \(channel.rawValue, privacy: .public) channel failed: \(error)"
            )
            throw error
        }
        log.notice(
            """
            Re-transcribed the \(channel.rawValue, privacy: .public) channel from \
            \(seconds, privacy: .public)s of audio into \
            \(collected.count, privacy: .public) lines
            """
        )
        return collected
    }
}
