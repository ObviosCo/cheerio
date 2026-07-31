import AVFoundation
import Foundation
import OSLog

/// Writes each capture channel to its own CAF file so a transcription failure
/// doesn't lose the meeting.
///
/// Buffers arrive from realtime audio callbacks and are drained onto the actor, so
/// no file I/O happens on the audio thread. Writing is best-effort: if a file can't
/// be created or a buffer can't be written, the meeting still records and
/// transcribes — it just has no audio backup.
public actor MeetingAudioRecorder {
    private struct Chunk: Sendable {
        let channel: SpeakerChannel
        let buffer: UnsafeTransfer<AVAudioPCMBuffer>
    }

    private let log = Logger(subsystem: "app.cheerio.mac", category: "MeetingAudioRecorder")
    private let directory: URL

    private var files: [SpeakerChannel: AVAudioFile] = [:]
    /// Channels whose file failed to open — don't retry on every buffer.
    private var failedChannels: Set<SpeakerChannel> = []
    private var drainTask: Task<Void, Never>?

    private let chunks: AsyncStream<Chunk>
    private let chunksContinuation: AsyncStream<Chunk>.Continuation

    public init(directory: URL) {
        self.directory = directory
        (self.chunks, self.chunksContinuation) = AsyncStream.makeStream()
    }

    /// Creates a directory for this meeting and a recorder writing into it.
    /// Returns the relative path to persist on the `Meeting`.
    public static func make() throws -> (recorder: MeetingAudioRecorder, relativePath: String) {
        let (relativePath, url) = try AudioStorage.makeMeetingDirectory()
        return (MeetingAudioRecorder(directory: url), relativePath)
    }

    public func start() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self, chunks] in
            for await chunk in chunks {
                await self?.write(chunk.buffer.value, channel: chunk.channel)
            }
        }
    }

    /// Safe to call from a realtime audio thread: it only enqueues. The buffer must
    /// be owned by the caller — pass a `detachedCopy()`.
    public nonisolated func submit(_ buffer: sending AVAudioPCMBuffer, channel: SpeakerChannel) {
        chunksContinuation.yield(Chunk(channel: channel, buffer: UnsafeTransfer(value: buffer)))
    }

    private func write(_ buffer: AVAudioPCMBuffer, channel: SpeakerChannel) {
        guard !failedChannels.contains(channel) else { return }
        do {
            let file = try file(for: channel, format: buffer.format)
            try file.write(from: buffer)
        } catch {
            // One failure per channel is enough to know audio backup is off.
            failedChannels.insert(channel)
            files[channel] = nil
            log.error("Audio recording disabled for \(channel.rawValue, privacy: .public): \(error)")
        }
    }

    private func file(for channel: SpeakerChannel, format: AVAudioFormat) throws -> AVAudioFile {
        if let existing = files[channel] { return existing }
        let url = directory.appending(path: "\(channel.rawValue).caf")
        // commonFormat/interleaved keep the file's processingFormat identical to the
        // captured format, so `write(from:)` doesn't need a conversion step.
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        files[channel] = file
        return file
    }

    /// Flushes queued buffers and closes the files.
    public func finish() async {
        chunksContinuation.finish()
        await drainTask?.value
        drainTask = nil
        // AVAudioFile finalizes its header on deallocation.
        files.removeAll()
    }
}
