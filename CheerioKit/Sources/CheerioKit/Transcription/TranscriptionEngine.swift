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

    private let updates: AsyncStream<TranscriptionUpdate>
    private let updatesContinuation: AsyncStream<TranscriptionUpdate>.Continuation

    public init(channel: SpeakerChannel, locale: Locale = .current) {
        self.channel = channel
        self.locale = locale
        (self.updates, self.updatesContinuation) = AsyncStream.makeStream()
    }

    /// Live transcription results. Volatile results have `isFinal == false`
    /// and are replaced by later updates; final results should be persisted.
    public nonisolated var results: AsyncStream<TranscriptionUpdate> { updates }

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

    /// Feed an audio buffer captured from the mic or system-audio tap.
    /// Buffers are converted to the analyzer's preferred format if needed.
    public func process(buffer: AVAudioPCMBuffer) {
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

        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, converted.frameLength > 0 {
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        }
    }

    public func stop() async throws {
        inputBuilder?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        converter = nil
    }
}
