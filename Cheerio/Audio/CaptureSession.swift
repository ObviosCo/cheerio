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

    /// Why the last start attempt failed, if it did.
    ///
    /// Lives on the session rather than in a view because recording can be started from
    /// the menu bar, and a menu can't host an alert — the failure has to survive long
    /// enough for the main window to present it.
    enum StartFailure: Equatable {
        case microphoneDenied
        case failed(String)

        var message: String? {
            switch self {
            case .microphoneDenied: nil
            case .failed(let message): message
            }
        }
    }

    var startFailure: StartFailure?

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
        do {
            try await startCapturing(title: title, calendarEventID: calendarEventID, context: context)
        } catch {
            // Half-started is the worst state to leave: engines running, the recorder
            // holding open files, possibly a live microphone, an empty meeting in the
            // library, and the UI stuck on "Preparing model…" with no way back. Unwind
            // all of it before handing the error up.
            await rollbackFailedStart(context: context)
            throw error
        }
    }

    private func startCapturing(
        title: String,
        calendarEventID: String?,
        context: ModelContext
    ) async throws {
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
            consumerTasks.append(
                Task { [weak self] in
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

    /// Waits for the transcript consumers to finish handing over their last updates.
    ///
    /// Bounded, because being wedged in `.finishing` with no stop button is worse than
    /// losing a few seconds of transcript.
    private func drainConsumers(timeout: Duration = .seconds(5)) async {
        let tasks = consumerTasks
        consumerTasks = []
        guard !tasks.isEmpty else { return }

        let watchdog = Task { [log] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            log.error("Transcript consumers didn't finish; the last lines may be missing")
            tasks.forEach { $0.cancel() }
        }
        for task in tasks { await task.value }
        watchdog.cancel()
    }

    /// Returns to `.idle` from a `start` that threw partway through, leaving nothing
    /// running and no empty meeting behind.
    private func rollbackFailedStart(context: ModelContext) async {
        micCapture?.stop()
        systemTap?.stop()
        try? await micEngine?.stop()
        try? await systemEngine?.stop()
        consumerTasks.forEach { $0.cancel() }
        consumerTasks = []
        await recorder?.finish()

        if let meeting {
            // Nothing was captured, so this would be an empty row in the library and an
            // empty directory on disk.
            if let relativePath = meeting.audioDirectory {
                try? AudioStorage.removeDirectory(atRelativePath: relativePath)
            }
            context.delete(meeting)
            try? context.save()
        }

        micEngine = nil
        systemEngine = nil
        micCapture = nil
        systemTap = nil
        recorder = nil
        meeting = nil
        startedAt = nil
        liveLines = []
        volatileLine = nil
        state = .idle
        log.error("Recording failed to start; rolled back")
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
        // Drain, don't cancel. Each engine's `stop()` finishes its results stream, so
        // these consumers end on their own once they've handed over every update —
        // and it's the final updates of the meeting that are still in flight here.
        // Cancelling dropped them, losing the tail of the transcript that the
        // summarizer then never saw.
        await drainConsumers()

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
                // After diarization, so the labels the owner names are matched against
                // are the ones the transcript actually carries.
                let notes = try await engine.generateEnhancedNotes(
                    transcript: meeting.transcriptText,
                    roughNotes: roughNotes,
                    ownerNames: SpeakerLabeling.ownerNames(context: context)
                )
                meeting.enhancedNotes = notes.markdown
                meeting.actionItems = notes.actionItems
            } catch {
                log.error("Enhancement failed: \(error)")
                // Transcript-only fallback: meeting remains useful without notes.
            }
            try? context.save()

            // The transcript is "ready" — issue #26's callback contract — right
            // here, and nowhere else: capture has stopped, diarization has run
            // (`catch` above notwithstanding — a failed pass still leaves the
            // channel-only labels, which is what a callback fired any earlier
            // would have shipped anyway), and enhancement has run or conclusively
            // failed. Firing before this point would hand the callback worse
            // speaker attribution than the app itself ends up showing, and labels
            // are exactly what the owner-attributed action items depend on.
            fireTranscriptReadyCallback(for: meeting, context: context)
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

    /// See the call site in ``stop(context:)`` for exactly which point in the
    /// pipeline this is — this function only builds the export and hands it to
    /// the runner, it doesn't decide when "ready" is.
    private func fireTranscriptReadyCallback(for meeting: Meeting, context: ModelContext) {
        let ownerNames = SpeakerLabeling.ownerNames(context: context)
        TranscriptReadyRunner.fireIfNeeded(export: meeting.export(ownerNames: ownerNames))
    }
}
