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
    /// The meeting from the last completed recording, kept after ``meeting`` is
    /// cleared so the UI can show its notes once we're idle again.
    private(set) var lastFinishedMeeting: Meeting?

    /// Live transcript lines for the UI. Volatile tail is replaced in place.
    private(set) var liveLines: [TranscriptionUpdate] = []
    private(set) var volatileLine: TranscriptionUpdate?

    var roughNotes: String = ""

    private let log = Logger(subsystem: "app.cheerio.mac", category: "CaptureSession")
    private var micEngine: TranscriptionEngine?
    private var systemEngine: TranscriptionEngine?
    private var micCapture: MicrophoneCapture?
    private var systemTap: SystemAudioTap?
    private var recorder: MeetingAudioRecorder?
    private var consumerTasks: [Task<Void, Never>] = []
    /// When the current recording began, for the elapsed-time readout.
    private(set) var startedAt: Date?

    func start(title: String, calendarEventID: String?, context: ModelContext) async throws {
        guard state == .idle else { return }
        state = .preparingModel
        try await TranscriptionEngine.ensureModel()

        let meeting = Meeting(title: title, calendarEventID: calendarEventID)
        // Start the roster at just your own voice: you're the one person guaranteed to
        // be here, and priming anyone else by default spends slots on people who may
        // not be. Left nil when no voice is marked "me", which keeps the old
        // everyone-enrolled behaviour.
        if let me = SpeakerLabeling.allEnrolled(context: context).first(where: \.isMe) {
            meeting.participantNames = [me.name]
        }
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
                    self?.handle(update, context: context)
                }
            })
        }

        // Audio-to-disk is a safety net, not a requirement: if it can't be set up
        // the meeting still records and transcribes.
        let recorder: MeetingAudioRecorder?
        do {
            let (made, relativePath) = try MeetingAudioRecorder.make()
            await made.start()
            meeting.audioDirectory = relativePath
            recorder = made
        } catch {
            log.error("Audio recording unavailable: \(error)")
            recorder = nil
        }
        self.recorder = recorder

        let micCapture = MicrophoneCapture { buffer in
            if let recorder, let forDisk = buffer.detachedCopy() {
                recorder.submit(forDisk, channel: .me)
            }
            micEngine.submit(buffer)
        }
        let systemTap = SystemAudioTap { buffer in
            if let recorder, let forDisk = buffer.detachedCopy() {
                recorder.submit(forDisk, channel: .them)
            }
            systemEngine.submit(buffer)
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
        await recorder?.finish()
        consumerTasks.forEach { $0.cancel() }
        consumerTasks = []

        if let meeting {
            meeting.endedAt = .now
            meeting.roughNotes = roughNotes

            // Diarize before summarizing, so the transcript the model reads carries
            // speaker labels — and before the retention purge, which would delete
            // the audio this reads.
            do {
                try await SpeakerLabeling.label(meeting: meeting, context: context)
            } catch {
                // Best-effort: the transcript keeps its channel labels.
                log.error("Speaker attribution failed: \(error)")
            }

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

        // Applies "Don't keep audio" immediately, and sweeps anything that aged out
        // while the app stayed open.
        do {
            try AudioRetentionService.purge(retention: .current, context: context)
        } catch {
            log.error("Audio retention purge failed: \(error)")
        }

        micEngine = nil
        systemEngine = nil
        micCapture = nil
        systemTap = nil
        recorder = nil
        lastFinishedMeeting = meeting
        meeting = nil
        state = .idle
    }
}
