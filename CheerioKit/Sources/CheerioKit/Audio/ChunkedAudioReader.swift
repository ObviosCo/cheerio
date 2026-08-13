import AVFoundation
import Foundation

/// Reads an audio file in bounded windows instead of one buffer sized to the whole
/// file.
///
/// Exists for `SpeakerAttributionService`: diarizing a 60-minute channel used to
/// mean `AudioConverter.resampleAudioFile` (FluidAudio) reading the whole thing into
/// one `[Float]` first — about 230 MB for that hour, before the model's own state.
/// Reading bounded windows and handing each one to the diarizer as it's read keeps
/// peak memory flat regardless of how long the recording is.
///
/// `AVAudioFile.read(into:frameCount:)` throws once `framePosition` has already
/// reached `length`, rather than returning an empty buffer — a "read until I get
/// nothing back" loop throws on its last lap. Every reader here guards on
/// `framePosition < length` instead, the same discipline `AudioExcerpt` already
/// uses within a single range.
///
/// It also short-reads: a single call can return fewer frames than requested well
/// before EOF, not just at the tail end — measured, a 250,000-frame request against
/// a file that long reliably came back with only 249,856 (see
/// `ChunkedAudioReaderTests.wholeFileRead`). Driving the loop off `framePosition`
/// rather than trusting one read to satisfy the whole request handles this for
/// free: a short read just means the next iteration picks up from wherever the
/// file actually left off.
public enum ChunkedAudioReader {
    public enum ReaderError: Error {
        case bufferAllocationFailed
    }

    /// Frames per window, at the file's native format. Bounds memory to a fixed
    /// size regardless of the recording's length — mono Float32 at 48 kHz, this is
    /// ~4 MB per window whether the file is a minute or an hour long.
    public static let defaultWindowFrames: AVAudioFrameCount = 1 << 20

    /// Reads `source` from its current position to the end, calling `onWindow`
    /// with each native-format window in turn.
    ///
    /// `source.framePosition` drives the loop end, not an empty-buffer check — see
    /// the type doc. Each window's buffer is reused by the caller as needed; this
    /// function never retains one past the call to `onWindow`.
    public static func read(
        _ source: AVAudioFile,
        windowFrames: AVAudioFrameCount = defaultWindowFrames,
        onWindow: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        let format = source.processingFormat
        while source.framePosition < source.length {
            let remaining = source.length - source.framePosition
            let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(windowFrames), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw ReaderError.bufferAllocationFailed
            }
            try source.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0 else { break }
            try onWindow(buffer)
        }
    }

    /// Reads `source` the same way, but hands each window to an *async* consumer
    /// and waits for it before reading the next.
    ///
    /// The waiting is the whole point. Re-transcription (issue #14) drives
    /// `TranscriptionEngine` from a file instead of from a microphone, and a file
    /// reads orders of magnitude faster than real time: yielding every window into
    /// the engine's queue as fast as the disk delivers them would hold the entire
    /// recording in memory at once — around 670 MB for the 58-minute,
    /// 3 ch / 24 kHz meeting issue #174 left behind, before the analyzer's own
    /// state. One window per consumer turn caps that at one window, however far
    /// behind the consumer runs.
    ///
    /// The loop is otherwise identical to ``read(_:windowFrames:onWindow:)`` —
    /// same `framePosition` end test, same tolerance for a short read.
    ///
    /// Its own name rather than an overload of `read`: a trailing closure carries no
    /// argument label, so an overload pair would let a *synchronous* closure written
    /// at an `await` call site silently resolve to the other function — which is
    /// exactly the unbounded read this exists to prevent, chosen by accident.
    public static func readAwaitingEachWindow(
        _ source: AVAudioFile,
        windowFrames: AVAudioFrameCount = defaultWindowFrames,
        onWindow: (sending AVAudioPCMBuffer) async throws -> Void
    ) async throws {
        let format = source.processingFormat
        while source.framePosition < source.length {
            let remaining = source.length - source.framePosition
            let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(windowFrames), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw ReaderError.bufferAllocationFailed
            }
            try source.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0 else { break }
            // `read(into:)` merges the fresh buffer into `source`'s region, which
            // leaves it task-isolated and so unsendable — the same accounting
            // `AVAudioPCMBuffer.detachedCopy()` documents. The box launders it
            // without a second copy, which is sound for the same reason: this
            // buffer was allocated one line ago, nothing else holds a reference,
            // and this loop never touches it again after handing it over.
            try await onWindow(UnsafeTransfer(value: buffer).value)
        }
    }
}
