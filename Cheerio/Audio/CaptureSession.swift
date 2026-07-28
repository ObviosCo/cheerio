import AVFoundation
import CheerioKit
import Foundation
import OSLog
import SwiftData

/// Orchestrates one meeting recording: mic + system audio capture, two
/// transcription engines, live transcript state, and persistence.
@MainActor
@Observable
final class CaptureSession {
    enum State {
        case idle
        case preparingModel
        case recording
        case finishing
    }

    private(set) var state: State = .idle
    private(set) var meeting: Meeting?

    /// Live transcript lines for the UI. Volatile tail is replaced in place.
    private(set) var liveLines: [TranscriptionUpdate] = []
    private(set) var volatileLine: TranscriptionUpdate?

    var roughNotes: String = ""

    private let log = Logger(subsystem: "app.cheerio.mac", category: "CaptureSession")
    private var micEngine: TranscriptionEngine?
    private var systemEngine: TranscriptionEngine?
    private var micCapture: MicrophoneCapture?
    private var systemTap: SystemAudioTap?
    private var consumerTasks: [Task<Void, Never>] = []
    private var startedAt: Date?

    func start(title: String, calendarEventID: String?, context: ModelContext) async throws {
        guard state == .idle else { return }
        state = .preparingModel
        try await TranscriptionEngine.ensureModel()

        let meeting = Meeting(title: title, calendarEventID: calendarEventID)
        context.insert(meeting)
        self.meeting = meeting
        self.startedAt = .now
        self.liveLines = []
        self.roughNotes = ""

        let micEngine = TranscriptionEngine(channel: .me)
        let systemEngine = TranscriptionEngine(channel: .them)
        self.micEngine = micEngine
        self.systemEngine = systemEngine
        try await micEngine.start()
        try await systemEngine.start()

        for engine in [micEngine, systemEngine] {
            consumerTasks.append(Task { [weak self] in
                for await update in engine.results {
                    await self?.handle(update, context: context)
                }
            })
        }

        let micCapture = MicrophoneCapture { buffer in
            Task { await micEngine.process(buffer: buffer) }
        }
        let systemTap = SystemAudioTap { buffer in
            Task { await systemEngine.process(buffer: buffer) }
        }
        self.micCapture = micCapture
        self.systemTap = systemTap
        try micCapture.start()
        try systemTap.start()

        state = .recording
        log.info("Recording started: \(title, privacy: .public)")
    }

    private func handle(_ update: TranscriptionUpdate, context: ModelContext) {
        if update.isFinal {
            volatileLine = nil
            liveLines.append(update)
            if let meeting {
                let segment = TranscriptSegment(
                    channel: update.channel,
                    text: update.text,
                    startTime: update.startTime,
                    endTime: update.endTime
                )
                segment.meeting = meeting
                context.insert(segment)
            }
        } else {
            volatileLine = update
        }
    }

    /// Stops capture, finalizes transcription, and kicks off enhancement.
    func stop(context: ModelContext) async {
        guard state == .recording else { return }
        state = .finishing

        micCapture?.stop()
        systemTap?.stop()
        try? await micEngine?.stop()
        try? await systemEngine?.stop()
        consumerTasks.forEach { $0.cancel() }
        consumerTasks = []

        if let meeting {
            meeting.endedAt = .now
            meeting.roughNotes = roughNotes
            do {
                let engine = SummarizationEngine()
                let notes = try await engine.generateEnhancedNotes(
                    transcript: meeting.transcriptText,
                    roughNotes: roughNotes
                )
                meeting.enhancedNotes = notes.markdown
            } catch {
                log.error("Enhancement failed: \(error)")
                // Transcript-only fallback: meeting remains useful without notes.
            }
            try? context.save()
        }

        micEngine = nil
        systemEngine = nil
        micCapture = nil
        systemTap = nil
        meeting = nil
        state = .idle
    }
}
