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

    /// Reads and returns the next window, or nil once `source` is exhausted.
    ///
    /// The single place this file's end-of-file and short-read discipline lives —
    /// see the type doc for both. ``read(_:windowFrames:onWindow:)`` is this in a
    /// loop; `TranscriptionEngine`'s file pass calls it one window at a time,
    /// because there the *analyzer* decides when it wants the next one (issue #14).
    ///
    /// Returns `sending`, so the window can be handed to an actor or a task without
    /// a second copy: it is allocated here, nothing else holds a reference, and this
    /// function never touches it again. `read(into:)` merges it into `source`'s
    /// region — the accounting `AVAudioPCMBuffer.detachedCopy()` documents — so the
    /// box is what tells the compiler what is already true.
    public static func nextWindow(
        from source: AVAudioFile,
        windowFrames: AVAudioFrameCount = defaultWindowFrames
    ) throws -> sending AVAudioPCMBuffer? {
        guard source.framePosition < source.length else { return nil }
        let remaining = source.length - source.framePosition
        let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(windowFrames), remaining))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: framesToRead) else {
            throw ReaderError.bufferAllocationFailed
        }
        try source.read(into: buffer, frameCount: framesToRead)
        guard buffer.frameLength > 0 else { return nil }
        return UnsafeTransfer(value: buffer).value
    }

    /// Reads `source` from its current position to the end, calling `onWindow`
    /// with each native-format window in turn.
    ///
    /// Each window's buffer is reused by the caller as needed; this function never
    /// retains one past the call to `onWindow`.
    public static func read(
        _ source: AVAudioFile,
        windowFrames: AVAudioFrameCount = defaultWindowFrames,
        onWindow: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        while let window = try nextWindow(from: source, windowFrames: windowFrames) {
            try onWindow(window)
        }
    }
}
