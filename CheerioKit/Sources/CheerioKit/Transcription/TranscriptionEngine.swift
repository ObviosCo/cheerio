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

    /// Public because the live transcript's *presentation* has to be reachable
    /// without a recording: the app's `RecordingSurfacePreview` renders fixture
    /// lines for the accessibility audits and the screenshot harness (#164), and
    /// the memberwise initializer of a public struct is internal to this package.
    /// Nothing here starts an analyzer — a line is a value, and one made this way
    /// is indistinguishable from one the engine emitted, which is the point: the
    /// audited view is the shipped view.
    public init(channel: SpeakerChannel, text: String, isFinal: Bool, startTime: TimeInterval, endTime: TimeInterval) {
        self.channel = channel
        self.text = text
        self.isFinal = isFinal
        self.startTime = startTime
        self.endTime = endTime
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
    /// Owns every format decision between the capture device and the analyzer —
    /// see `AnalyzerAudioConverter` for why the channel count is collapsed there
    /// rather than left to `AVAudioConverter`.
    private var converter: AnalyzerAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    /// The file a ``transcribe(file:)`` pass is reading, held only for that pass. A
    /// box rather than the `AVAudioFile` itself so the actor's stored property can
    /// take the `sending` handoff (`AVAudioFile` isn't `Sendable`) without the
    /// compiler having to reason about a whole actor's worth of state.
    private var fileWindows: FileWindows?
    /// A read failure from inside the analyzer's own iteration, kept until
    /// ``transcribe(file:)`` can throw it — see ``nextFileInput()``.
    private var fileReadFailure: Error?

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

    /// Transcribes a file end to end, returning once the analyzer has consumed all
    /// of it. Re-transcribing a retained recording (issue #14); call ``stop()``
    /// afterwards, exactly as a live channel does, to finalize and collect the tail.
    ///
    /// **The analyzer pulls; nothing pushes.** A file reads orders of magnitude
    /// faster than speech recognition runs, so any design where the reader hands
    /// buffers *to* a queue can outrun the consumer — and `AsyncStream`'s default
    /// buffering is unbounded, so "can outrun" means an hour of audio resident at
    /// once (issue #117's lesson, learned on diarization). This path has no queue at
    /// all: the input sequence's iterator asks ``nextFileInput()`` for one window at
    /// the moment the analyzer wants it, so exactly one window and its conversion
    /// are ever in flight, whatever the recording's length. There is no gate to
    /// tune, no watermark to trust, and nothing to deadlock — the buffer that
    /// doesn't exist can't grow.
    ///
    /// Measured, over 58 minutes of mono 16 kHz audio in a release build
    /// (`RetranscriptionMemoryTests`, the harness `DiarizationMemoryTests`
    /// established for #117): pushing into an unbounded stream peaked at **52
    /// converted windows queued** — around 110 MB nothing would reclaim until the
    /// pass ended — and 136 MB peak RSS. Pulling: one window in flight, 47 MB peak
    /// RSS, against 45 MB for the same test over 10 minutes. Peak memory tracks the
    /// window size, not the length of the meeting.
    ///
    /// Same converter, same analyzer, same everything downstream as a microphone —
    /// a file pass inherits every fix the live path gets (`AnalyzerAudioConverter`,
    /// issue #174) because from the conversion onward it *is* the live path.
    ///
    /// `file` is consumed: it's read to its end from wherever its position is, and
    /// the engine keeps it for the duration of the pass. A read failure ends the
    /// input — finalizing whatever was transcribed up to that point — and is
    /// rethrown here rather than out of the analyzer's own iteration.
    public func transcribe(file: sending AVAudioFile) async throws {
        guard analyzer == nil else { throw TranscriptionError.enginePassAlreadyRan }
        await prepare()
        guard let analyzer else { throw TranscriptionError.analyzerUnavailable }
        fileWindows = FileWindows(file: file)
        _ = try await analyzer.analyzeSequence(PulledFileInput(engine: self))
        fileWindows = nil
        if let fileReadFailure {
            self.fileReadFailure = nil
            throw fileReadFailure
        }
    }

    /// One converted window, or nil at the end of the file — called by the analyzer,
    /// through ``PulledFileInput``, once per window it is ready to analyze. This
    /// being the only way audio enters the file pass is what makes the pass
    /// backpressured by construction; see ``transcribe(file:)``.
    ///
    /// Non-throwing on purpose: the analyzer's input sequence has the same
    /// `Failure == Never` shape it has on the live path, so a read error is recorded
    /// and ends the input rather than unwinding through Speech's own iteration.
    /// ``transcribe(file:)`` is what reports it.
    ///
    /// A window the converter refuses (it logs, once per format) is skipped rather
    /// than ending the pass — the alternative is abandoning the rest of a meeting
    /// over one bad window.
    fileprivate func nextFileInput() -> AnalyzerInput? {
        guard let fileWindows else { return nil }
        do {
            while let window = try ChunkedAudioReader.nextWindow(from: fileWindows.file) {
                if let converted = converted(window) {
                    return AnalyzerInput(buffer: converted)
                }
            }
            return nil
        } catch {
            fileReadFailure = error
            return nil
        }
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
        await prepare()
        guard let analyzer else { throw TranscriptionError.analyzerUnavailable }

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputBuilder = inputBuilder
        try await analyzer.start(inputSequence: inputSequence)

        audioTask = Task { [weak self, capturedAudio] in
            for await chunk in capturedAudio {
                await self?.process(buffer: chunk.value)
            }
        }
    }

    /// The transcriber, the analyzer, the format they agree on, and the task that
    /// drains results into ``results`` — everything both entry points need before
    /// audio starts arriving, from a microphone (``start()``) or from a file
    /// (``transcribe(file:)``).
    ///
    /// The results task is started here rather than by each caller, so no window
    /// exists in which the transcriber is emitting and nothing is listening.
    private func prepare() async {
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

    /// Pushes one captured buffer to the analyzer — the live path, where audio
    /// arrives when the hardware says so and there is nobody to pull it.
    private func process(buffer: sending AVAudioPCMBuffer) {
        guard let inputBuilder, let converted = converted(buffer) else { return }
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    /// Converts a buffer into the analyzer's format — whatever the device handed us,
    /// at whatever channel count and sample rate.
    ///
    /// Nothing here assumes the capture format: `analyzerFormat` is what the
    /// transcriber asked for, and `AnalyzerAudioConverter` derives the whole
    /// conversion from the buffer's own format on each buffer, rebuilding when a
    /// device switch changes it mid-recording. Shared by both directions, so a file
    /// pass and a microphone are converted by the same code — see
    /// ``transcribe(file:)``.
    private func converted(_ buffer: sending AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let analyzerFormat else {
            // No preferred format to convert to — feed the capture format through
            // and let the analyzer decide what it can do with it.
            return buffer
        }
        if converter == nil {
            converter = AnalyzerAudioConverter(channel: channel, target: analyzerFormat)
        }
        return converter?.convert(buffer)
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
        fileWindows = nil

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

/// What can go wrong setting a pass up, as distinct from what Speech itself
/// reports.
public enum TranscriptionError: Error {
    /// `SpeechAnalyzer` wasn't constructible — nothing downstream can run.
    case analyzerUnavailable
    /// An engine is one pass: a live recording or one file. Reusing it would leave
    /// the previous pass's transcriber, results task and converter in place.
    case enginePassAlreadyRan
}

/// The file a ``TranscriptionEngine/transcribe(file:)`` pass is reading.
///
/// Exists so an `AVAudioFile` — not `Sendable`, and not something region isolation
/// can follow into an actor's stored property — can be handed over once and then
/// live entirely on the actor. Nothing outside the actor ever reads it.
private final class FileWindows {
    let file: AVAudioFile

    init(file: sending AVAudioFile) {
        self.file = file
    }
}

/// `SpeechAnalyzer`'s input for a file pass: a sequence that reads and converts one
/// window each time the analyzer asks for the next element.
///
/// This is the whole backpressure mechanism, and it's a structural one — there is no
/// buffer between the file and the analyzer to overflow, no high-water mark to pick,
/// and no producer to suspend. The analyzer's own pace is the read rate, so peak
/// memory is one window plus its conversion whether the recording is a minute or an
/// hour. (Contrast the live path, which must *push*: audio arrives when the hardware
/// says so, and its `AsyncStream` is unbounded because a microphone can't outrun the
/// analyzer by more than the length of the recording in real time.)
///
/// `Failure` stays `Never`, like the live path's `AsyncStream`, so a read error ends
/// the input and is reported by `transcribe(file:)` instead of unwinding through
/// Speech's iteration — see `TranscriptionEngine.nextFileInput()`.
private struct PulledFileInput: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    typealias Failure = Never

    let engine: TranscriptionEngine

    struct Iterator: AsyncIteratorProtocol {
        let engine: TranscriptionEngine

        func next() async -> AnalyzerInput? {
            await engine.nextFileInput()
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(engine: engine)
    }
}
