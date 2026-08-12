import AVFoundation
import CheerioKit
import Foundation
import OSLog
import Synchronization

/// Captures microphone audio via AVAudioEngine and delivers PCM buffers.
/// This is the "Me" channel. Portable to iOS as-is (move to CheerioKit in v2).
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let onBuffer: @Sendable (sending AVAudioPCMBuffer) -> Void
    private static let log = Logger(subsystem: "co.obvios.cheerio.mac", category: "MicrophoneCapture")

    /// One reading per tap buffer — a live mic-level meter that can be armed
    /// before recording starts (the enrollment flow's "Mic check") or watched
    /// alongside an actual recording, from the same tap. `AudioLevel.measuring`
    /// is cheap enough to run on the buffer directly inside the tap closure, so
    /// only the resulting scalar crosses into this stream — never the buffer.
    ///
    /// `.bufferingNewest(1)`, unlike every other `AsyncStream` in this codebase:
    /// those hold audio or transcription results that all have to survive to be
    /// written or transcribed, but a meter only ever cares about the latest
    /// reading. `CaptureSession` doesn't consume this stream during a real
    /// meeting at all — only the enrollment view does — so an unbounded buffer
    /// would otherwise retain one `AudioLevel` per tap buffer for the length of
    /// the recording, for a value nothing downstream is watching.
    let levels: AsyncStream<AudioLevel>
    private let levelsContinuation: AsyncStream<AudioLevel>.Continuation

    /// A quiet mic doesn't reliably fail loud. A denied TCC grant fails at
    /// `permission()` when the user answers the prompt, but a grant revoked in
    /// System Settings or an input device pointed at nothing both leave the
    /// engine running and the tap firing — every buffer just reads (near-)zero,
    /// and issue #159's meeting loses its whole Me channel with no error
    /// anywhere. This watches the peak across the recording — fed from
    /// the same `AudioLevel` each tap buffer already computes for `levels`, so the
    /// samples are never scanned twice — and `stop()` logs the verdict, the mic's
    /// counterpart to `SystemAudioTap`'s `SilenceWatch`.
    private let peakWatch = CapturePeakWatch()

    /// Armed by the caller, not by `start()`, because only the caller knows when
    /// the recording it is assembling is genuinely underway. `CaptureSession`
    /// starts this engine *before* `SystemAudioTap`; if the tap then throws, its
    /// rollback stops a mic that ran for under a second during which nobody was
    /// asked to speak — a verdict there would log a TCC diagnosis for a recording
    /// that never existed. Same for an enrollment take cancelled mid-setup. An
    /// unarmed watch stays quiet, and the enrollment mic check never arms at all:
    /// it runs the tap while somebody watches a level meter, possibly without
    /// saying a word — same reasoning as `SystemAudioTap`'s onboarding probe.
    private let verdictArmed = Atomic<Bool>(false)

    init(onBuffer: @escaping @Sendable (sending AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        (levels, levelsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Call once every capture source in the session has started and the
    /// recording is really on — from then on, `stop()` logs the verdict.
    func armSilenceVerdict() {
        verdictArmed.store(true, ordering: .releasing)
    }

    enum Permission {
        case granted
        /// The user said no, or an administrator disallows it. Only System Settings
        /// can change this — asking again does nothing.
        case denied
    }

    /// Only prompts the first time. Once the user has decided, `requestAccess`
    /// silently returns the stored answer, so re-asking on every recording just
    /// produces the same result — and a dead-end error if it was "no".
    static func permission() async -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// Plain capture, deliberately: voice processing (acoustic echo cancellation, AGC,
    /// ducking) used to be an option here and was removed after it silenced a real
    /// meeting's entire Me channel with no error anywhere (issues #159, #167). The
    /// double-transcription it targeted — the mic hearing the speakers — remains an
    /// open, tracked problem, being addressed at the transcript level (#168) rather
    /// than here: `start()` makes no echo guarantee. Everything downstream (the converter feeding
    /// `SpeechAnalyzer`, the CAF writer) takes its format from the buffer it's handed
    /// rather than from a fixed assumption.
    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [onBuffer, levelsContinuation, peakWatch] buffer, _ in
            // Measured on the tap's own buffer, before the copy below — reading
            // samples that are already resident costs nothing a level meter
            // couldn't also cost by way of a bigger copy handed downstream. One
            // measurement serves both consumers: the meter takes the reading as
            // is, the peak watch folds its `peak` into the recording-wide max.
            let level = AudioLevel.measuring(buffer)
            levelsContinuation.yield(level)
            peakWatch.record(peak: level.peak)
            // The tap recycles `buffer` after this returns; the transcription
            // engine outlives the callback, so hand it a copy it owns.
            guard let copy = buffer.detachedCopy() else { return }
            onBuffer(copy)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        levelsContinuation.finish()
        logSilenceVerdict()
    }

    /// The exchange makes the verdict once-only: some teardown paths can reach
    /// `stop()` twice, and the second pass shouldn't log a duplicate.
    private func logSilenceVerdict() {
        guard verdictArmed.exchange(false, ordering: .acquiringAndReleasing) else { return }
        let verdict = peakWatch.verdict
        switch verdict {
        case .signal:
            // .notice so it survives to `log show`; .info is memory-only.
            Self.log.notice("Microphone capture stopped — captured signal, peak \(verdict.peakDescription, privacy: .public)")
        case .silence:
            Self.log.error(
                """
                Microphone capture stopped — captured ONLY SILENCE (peak \(verdict.peakDescription, privacy: .public)). \
                The engine ran without error but the Me channel is empty. Most likely: microphone access is \
                denied (System Settings → Privacy & Security → Microphone — the co.obvios.cheerio.mac \
                bundle-identifier change reset the old grant), or the selected input \
                (System Settings → Sound → Input) isn't the device hearing the room.
                """
            )
        }
    }
}
