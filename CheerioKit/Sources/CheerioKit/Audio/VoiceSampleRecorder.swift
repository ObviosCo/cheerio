import AVFoundation
import Foundation
import OSLog

/// Records a single mono voice sample to one CAF file, for speaker enrollment.
///
/// Separate from ``MeetingAudioRecorder`` because that one writes a file per
/// capture channel and names files after them; enrollment is one voice, one file.
/// Buffers arrive from a realtime callback and are drained onto the actor, so no
/// file I/O happens on the audio thread.
public actor VoiceSampleRecorder {
    private let log = Logger(subsystem: "co.obvios.cheerio.mac", category: "VoiceSampleRecorder")
    private let destination: URL

    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var writeFailed = false
    private var drainTask: Task<Void, Never>?

    private let buffers: AsyncStream<UnsafeTransfer<AVAudioPCMBuffer>>
    private let buffersContinuation: AsyncStream<UnsafeTransfer<AVAudioPCMBuffer>>.Continuation

    public init(destination: URL) {
        self.destination = destination
        (self.buffers, self.buffersContinuation) = AsyncStream.makeStream()
    }

    public func start() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self, buffers] in
            for await buffer in buffers {
                await self?.write(buffer.value)
            }
        }
    }

    /// Safe to call from a realtime audio thread: it only enqueues. Pass a
    /// `detachedCopy()` — the caller must own the buffer.
    public nonisolated func submit(_ buffer: sending AVAudioPCMBuffer) {
        buffersContinuation.yield(UnsafeTransfer(value: buffer))
    }

    /// Seconds recorded so far, for a live duration readout.
    public var duration: TimeInterval {
        sampleRate > 0 ? TimeInterval(framesWritten) / sampleRate : 0
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard !writeFailed else { return }
        do {
            let file = try file ?? makeFile(format: buffer.format)
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            writeFailed = true
            self.file = nil
            log.error("Voice sample recording failed: \(error)")
        }
    }

    private func makeFile(format: AVAudioFormat) throws -> AVAudioFile {
        let made = try AVAudioFile(
            forWriting: destination,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        file = made
        sampleRate = format.sampleRate
        return made
    }

    /// Flushes queued buffers, closes the file, and reports how long the sample is.
    /// Returns nil if nothing usable was written.
    @discardableResult
    public func finish() async -> TimeInterval? {
        buffersContinuation.finish()
        await drainTask?.value
        drainTask = nil
        // AVAudioFile finalizes its header on deallocation.
        file = nil
        guard !writeFailed, framesWritten > 0 else { return nil }
        return duration
    }
}
