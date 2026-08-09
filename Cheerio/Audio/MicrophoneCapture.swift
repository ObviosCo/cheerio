import AVFoundation
import CheerioKit
import Foundation
import OSLog

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
    let levels: AsyncStream<AudioLevel>
    private let levelsContinuation: AsyncStream<AudioLevel>.Continuation

    init(onBuffer: @escaping @Sendable (sending AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        (levels, levelsContinuation) = AsyncStream.makeStream()
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

    /// `mode` decides whether to try enabling acoustic echo cancellation — never whether
    /// capture starts. Voice processing has to be flipped before the engine starts, and it
    /// can change what `outputFormat(forBus:)` reports, so the format is read *after* that
    /// call, not assumed. Everything downstream (the converter feeding `SpeechAnalyzer`, the
    /// CAF writer) already takes its format from the buffer it's handed rather than from a
    /// fixed assumption, so whatever format voice processing settles on just flows through.
    func start(mode: RecordingMode) throws {
        let input = engine.inputNode
        if mode.echoCancellationEnabled {
            enableEchoCancellation(on: input)
        }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [onBuffer, levelsContinuation] buffer, _ in
            // Measured on the tap's own buffer, before the copy below — reading
            // samples that are already resident costs nothing a level meter
            // couldn't also cost by way of a bigger copy handed downstream.
            levelsContinuation.yield(AudioLevel.measuring(buffer))
            // The tap recycles `buffer` after this returns; the transcription
            // engine outlives the callback, so hand it a copy it owns.
            guard let copy = buffer.detachedCopy() else { return }
            onBuffer(copy)
        }
        engine.prepare()
        try engine.start()
    }

    /// Best-effort: voice processing can reject a device or format outright, and failing the
    /// whole recording over a nicety would be worse than the echo it's meant to remove — see
    /// issue #5's design comment. Falls back to capturing without echo cancellation and logs
    /// why, rather than throwing.
    private func enableEchoCancellation(on input: AVAudioInputNode) {
        do {
            try input.setVoiceProcessingEnabled(true)
            // AGC is a separate toggle from AEC and defaults to on once voice processing is
            // enabled. Automatic gain on a meeting mic isn't obviously desirable — it can
            // pump the level around as people vary in loudness — so it's turned off
            // explicitly rather than left to ride along with AEC.
            input.isVoiceProcessingAGCEnabled = false
            // Voice processing also ducks "other" (non-voice) audio by default, at the
            // level tuned for typical voice chat. That's the wrong default here: the
            // "other" audio it would duck is the far-end call itself, which is both what
            // the user is listening to and what SystemAudioTap is recording on the Them
            // channel — ducking it would quietly attenuate the very signal the other
            // channel needs, and confound the #5 A/B measurement into the bargain. Pin it
            // to the minimum rather than leave the default active.
            //
            // `duckingLevel` and `enableAdvancedDucking` are independent per
            // AVAudioIONode.h: the level sets the base attenuation regardless of the
            // flag (the header documents the shipped default as *disabled* advanced
            // ducking paired with `duckingLevel = .default`, which only makes sense if
            // the level applies either way), and advanced ducking layers *additional*,
            // voice-activity-driven attenuation on top. Leaving it `false` here is the
            // right call, not a gap — turning it on would add ducking, not make `.min`
            // "count".
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
        } catch {
            // .notice, not .info: .info-level os_log entries never reach `log show`, and this
            // is exactly the kind of silent failure issue #5 warned against.
            Self.log.notice(
                "Voice processing unavailable, continuing without echo cancellation: \(error)")
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        levelsContinuation.finish()
    }
}
