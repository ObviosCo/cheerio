import AVFoundation
import Foundation
import Speech

/// A finalized or in-progress piece of transcription from one audio channel.
public struct TranscriptionUpdate: Sendable {
    public let channel: SpeakerChannel
    public let text: String
    public let isFinal: Bool
    public let startTime: TimeInterval
    public let endTime: TimeInterval
}

/// Holds the single buffer an `AVAudioConverter` pass should consume, and yields
/// it exactly once. Sound because the converter invokes its input block
/// synchronously on the thread that called `convert`.
private final class PendingInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: sending AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Wraps SpeechAnalyzer/SpeechTranscriber (macOS/iOS 26+) for one audio stream.
/// Create one engine per channel (mic = .me, system audio = .them).
public actor TranscriptionEngine {
    public let channel: SpeakerChannel
    private let locale: Locale

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?

    private let updates: AsyncStream<TranscriptionUpdate>
    private let updatesContinuation: AsyncStream<TranscriptionUpdate>.Continuation

    /// Buffers arrive here straight from a realtime audio callback and are
    /// drained onto the actor in order, so the callback itself never blocks.
    private let capturedAudio: AsyncStream<UnsafeTransfer<AVAudioPCMBuffer>>
    private let capturedAudioContinuation: AsyncStream<UnsafeTransfer<AVAudioPCMBuffer>>.Continuation

    public init(channel: SpeakerChannel, locale: Locale = .current) {
        self.channel = channel
        self.locale = locale
        (self.updates, self.updatesContinuation) = AsyncStream.makeStream()
        (self.capturedAudio, self.capturedAudioContinuation) = AsyncStream.makeStream()
    }

    /// Live transcription results. Volatile results have `isFinal == false`
    /// and are replaced by later updates; final results should be persisted.
    public nonisolated var results: AsyncStream<TranscriptionUpdate> { updates }

    /// Hands a captured buffer to the engine. Safe to call from a realtime audio
    /// thread: it only enqueues.
    ///
    /// The buffer must be owned by the caller — buffers vended by an AVAudioEngine
    /// tap or a Core Audio IOProc are recycled the moment the callback returns, so
    /// pass `detachedCopy()` output, not the original.
    public nonisolated func submit(_ buffer: sending AVAudioPCMBuffer) {
        capturedAudioContinuation.yield(UnsafeTransfer(value: buffer))
    }

    /// Ensures the on-device model for `locale` is installed. Call before `start()`.
    /// First run downloads the model; surface progress in UI.
    public static func ensureModel(for locale: Locale = .current) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    public func start() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputBuilder = inputBuilder
        try await analyzer.start(inputSequence: inputSequence)

        audioTask = Task { [weak self, capturedAudio] in
            for await chunk in capturedAudio {
                await self?.process(buffer: chunk.value)
            }
        }

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    await self.emit(result)
                }
            } catch {
                // Analyzer finished or failed; stream ends.
            }
            await self.finishUpdates()
        }
    }

    private func emit(_ result: SpeechTranscriber.Result) {
        let timeRange = result.range
        updatesContinuation.yield(
            TranscriptionUpdate(
                channel: channel,
                text: String(result.text.characters),
                isFinal: result.isFinal,
                startTime: timeRange.start.seconds,
                endTime: timeRange.end.seconds
            )
        )
    }

    private func finishUpdates() {
        updatesContinuation.finish()
    }

    /// Converts a captured buffer to the analyzer's preferred format if needed
    /// and feeds it in.
    private func process(buffer: sending AVAudioPCMBuffer) {
        guard let inputBuilder else { return }
        guard let analyzerFormat, buffer.format != analyzerFormat else {
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.outputFormat != analyzerFormat {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
        }
        guard let converter,
              let converted = AVAudioPCMBuffer(
                pcmFormat: analyzerFormat,
                frameCapacity: AVAudioFrameCount(
                    Double(buffer.frameLength) * analyzerFormat.sampleRate / buffer.format.sampleRate
                ) + 1
              )
        else { return }

        // AVAudioConverterInputBlock is @Sendable, but the converter calls it
        // synchronously before `convert` returns — the box just carries the
        // one-shot input past that annotation.
        let pending = PendingInput(buffer: buffer)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            guard let next = pending.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        if error == nil, converted.frameLength > 0 {
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        }
    }

    public func stop() async throws {
        // Let already-queued buffers reach the analyzer before finalizing, so the
        // tail of the meeting isn't dropped.
        capturedAudioContinuation.finish()
        await audioTask?.value
        audioTask = nil
        inputBuilder?.finish()

        // Hold the error rather than throwing straight out: cleanup has to happen
        // either way, or `resultsTask` — which retains `self` — keeps this engine and
        // its analyzer alive for the life of the process.
        var finalizeError: Error?
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            finalizeError = error
        }

        if finalizeError == nil {
            // Drain, don't cancel. Finalizing ends `transcriber.results`, and the last
            // final results of the meeting are delivered right here — cancelling threw
            // away the tail of every recording.
            await drainResults()
        } else {
            // Finalizing failed, so nothing more is coming and the stream may never
            // end by itself.
            resultsTask?.cancel()
            await resultsTask?.value
        }

        resultsTask = nil
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        converter = nil

        if let finalizeError { throw finalizeError }
    }

    /// Waits for the results task to finish, but not forever.
    ///
    /// If a module's result stream doesn't end after finalizing, `stop()` still has to
    /// return — otherwise the UI sits on "Finishing up…" with no way out. Losing the
    /// last words beats never finishing.
    private func drainResults(timeout: Duration = .seconds(5)) async {
        guard let resultsTask else { return }
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            resultsTask.cancel()
        }
        await resultsTask.value
        watchdog.cancel()
    }
}
