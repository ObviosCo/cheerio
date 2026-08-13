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
/// regress that fix on its own. So this owns exactly two things the live path
/// doesn't have: where the buffers come from, and the fact that a file outruns the
/// analyzer.
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
    /// `ensureModel` is called for the same reason the live path calls it, and it
    /// is not a network dependency in practice: a meeting that transcribed at all
    /// has the locale's asset installed already, so this returns without asking
    /// for anything. A locale that was never installed is the one case where it
    /// would download, exactly as starting a recording in that locale would.
    public static func transcribe(
        audioFile: URL,
        channel: SpeakerChannel,
        locale: Locale = .current,
        windowFrames: AVAudioFrameCount = ChunkedAudioReader.defaultWindowFrames
    ) async throws -> [TranscriptionUpdate] {
        let file = try AVAudioFile(forReading: audioFile)
        try await TranscriptionEngine.ensureModel(for: locale)

        let engine = TranscriptionEngine(channel: channel, locale: locale)
        try await engine.start()

        // Started before the first buffer goes in: the engine's result stream is
        // live from `start()`, and a consumer attached later would miss whatever
        // finalized in between.
        let lines = Task {
            var collected: [TranscriptionUpdate] = []
            for await update in engine.results where update.isFinal {
                collected.append(update)
            }
            return collected
        }

        var readError: Error?
        do {
            try await ChunkedAudioReader.readAwaitingEachWindow(file, windowFrames: windowFrames) { window in
                await engine.feed(window)
            }
        } catch {
            readError = error
        }

        // Stopped on both paths, and awaited either way: `stop()` finalizes the
        // analyzer and ends the result stream, so it's also what lets the
        // collector above finish. Skipping it after a read failure would leave
        // that task — and the analyzer it holds — running for the life of the
        // process.
        var stopError: Error?
        do {
            try await engine.stop()
        } catch {
            stopError = error
        }
        let collected = await lines.value

        if let error = readError ?? stopError {
            log.error(
                "Re-transcribing the \(channel.rawValue, privacy: .public) channel failed: \(error)"
            )
            throw error
        }
        log.notice(
            """
            Re-transcribed the \(channel.rawValue, privacy: .public) channel from \
            \(Int(file.durationSeconds), privacy: .public)s of audio into \
            \(collected.count, privacy: .public) lines
            """
        )
        return collected
    }
}
