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
    /// The calendar occurrence's own start date for ``meeting``, if it was started
    /// against one — distinct from `Meeting.startedAt`, which is when capture
    /// actually began and so can't stand in for it. `NotificationService` pairs
    /// this with `meeting.calendarEventID` to build the exact occurrence key it
    /// vetoes, rather than the raw event id, which repeats across every occurrence
    /// of a recurring event.
    private(set) var calendarEventOccurrenceStart: Date?
    /// The same pairing as ``calendarEventOccurrenceStart``, snapshotted alongside
    /// ``lastFinishedMeeting`` at the moment it's set, for the same reason
    /// ``lastFinishedMeeting`` itself exists: `NotificationService` still needs it
    /// once ``meeting`` and ``calendarEventOccurrenceStart`` have both gone back to
    /// nil.
    private(set) var lastFinishedMeetingOccurrenceStart: Date?

    /// Meetings with a background mutation in flight outside this session's own
    /// pipeline — today, just `MeetingDetailView`'s manual "Re-identify speakers"
    /// button. The pass this session runs itself at the end of a recording needs no
    /// entry here: ``meeting`` stays set through `.finishing`, so ``canDelete(_:)``
    /// already covers it.
    ///
    /// Keyed by `persistentModelID`, not the `Meeting` itself, on purpose — this is
    /// the one piece of shared state every delete affordance consults, and holding
    /// a `Meeting` here past a delete would be exactly the "still holding a model
    /// SwiftData just removed" bug this exists to prevent.
    ///
    /// This is the app's one shared `@Observable`, which is why a cross-cutting
    /// concern like "is anything mutating this meeting right now" lives here rather
    /// than on a purpose-built type — the alternative costs a new object threaded
    /// into every scene in `CheerioApp` for one small set.
    private var processingMeetingIDs: Set<PersistentIdentifier> = []

    /// Marks `meeting` as having a background mutation in flight. Call before the
    /// first suspension point of whatever's about to `await` its way through
    /// changing it, and unconditionally clear with ``endProcessing(_:)`` in a
    /// `defer` — on the success path and the failure path alike, or a thrown error
    /// leaves the meeting permanently undeletable.
    func beginProcessing(_ meeting: Meeting) {
        processingMeetingIDs.insert(meeting.persistentModelID)
    }

    func endProcessing(_ meeting: Meeting) {
        processingMeetingIDs.remove(meeting.persistentModelID)
    }

    /// Whether every delete affordance should treat `meeting` as safe to remove
    /// right now: not the meeting actively recording (``meeting`` stays set through
    /// `.finishing`, so this covers that phase too), and nothing else has it
    /// mid-mutation per ``beginProcessing(_:)``.
    ///
    /// A disabled button rather than cancel-and-await, for a first pass — see the
    /// call sites in `MeetingListView` and `MeetingDetailView`.
    func canDelete(_ meeting: Meeting) -> Bool {
        meeting != self.meeting && !processingMeetingIDs.contains(meeting.persistentModelID)
    }

    /// Call after successfully deleting a meeting, so this session stops holding
    /// a reference to a model SwiftData just removed.
    ///
    /// `meeting` itself never needs checking here — `canDelete(_:)` already
    /// forbids deleting the active recording, so this can only ever be
    /// ``lastFinishedMeeting``. But that one *does* need it:
    /// `NotificationService.recordingContext` reads
    /// `lastFinishedMeeting?.calendarEventID` on a five-minute reconcile loop
    /// that has no idea the meeting behind it might be gone, and this deletion
    /// helper's own contract is that the model is unusable once its delete is
    /// saved. Clearing the occurrence timestamp alongside it keeps the two in
    /// the paired, both-or-neither state ``lastFinishedMeetingOccurrenceStart``
    /// already documents.
    func meetingWasDeleted(_ meetingID: PersistentIdentifier) {
        guard lastFinishedMeeting?.persistentModelID == meetingID else { return }
        lastFinishedMeeting = nil
        lastFinishedMeetingOccurrenceStart = nil
    }

    /// Live transcript lines for the UI. Volatile tail is replaced in place.
    private(set) var liveLines: [TranscriptionUpdate] = []
    private(set) var volatileLine: TranscriptionUpdate?

    var roughNotes: String = ""

    private let log = Logger(subsystem: "co.obvios.cheerio.mac", category: "CaptureSession")
    private var micEngine: TranscriptionEngine?
    private var systemEngine: TranscriptionEngine?
    private var micCapture: MicrophoneCapture?
    private var systemTap: SystemAudioTap?
    private var recorder: MeetingAudioRecorder?
    private var consumerTasks: [Task<Void, Never>] = []
    /// Flushes finalized transcript segments to disk on ``checkpointInterval``'s
    /// cadence — see ``startCheckpointing(context:)``. Cancelled in ``stop(context:)``,
    /// which takes over saving explicitly from that point on, and defensively in
    /// ``rollbackFailedStart()``, which in practice never finds it running.
    private var checkpointTask: Task<Void, Never>?
    /// How often ``handle(_:context:)``'s inserts are checkpointed while recording.
    ///
    /// Off the realtime audio path entirely — ``handle`` already runs on this
    /// (main) actor, not the audio callback, and this loop is a second, independent
    /// task that only ever touches the `ModelContext`. Bounds staleness for
    /// *finalized* segments only: ``handle`` inserts a `TranscriptSegment` when an
    /// update's `isFinal` is true, and this loop only ever saves what's already in
    /// the context — ``volatileLine``, the line currently being spoken, is never
    /// inserted at all, so a reader doesn't see it on this cadence or any other; it
    /// appears only once transcription finalizes it. For what this does bound, the
    /// interval is a trade between two readers: a second process (the MCP helper)
    /// watching an in-progress meeting sees each finalized line within this long of
    /// it finalizing, and a shorter interval spends more disk I/O contending with
    /// the same context transcription is inserting into. Two seconds is short
    /// enough that "in progress" reads as live, long enough that it coalesces the
    /// common case of both channels finalizing a line within the same second or two
    /// of each other into one save instead of two.
    private static let checkpointInterval: Duration = .seconds(2)
    /// When the current recording began, for the elapsed-time readout.
    private(set) var startedAt: Date?

    func start(
        title: String,
        calendarEventID: String?,
        calendarEventOccurrenceStart: Date? = nil,
        kind: MeetingKind = .meeting,
        context: ModelContext
    ) async throws {
        guard state == .idle else { return }
        state = .preparingModel
        do {
            try await startCapturing(
                title: title,
                calendarEventID: calendarEventID,
                calendarEventOccurrenceStart: calendarEventOccurrenceStart,
                kind: kind,
                context: context)
        } catch {
            // Half-started is the worst state to leave: engines running, the recorder
            // holding open files, possibly a live microphone, and the UI stuck on
            // "Preparing model…" with no way back. Unwind all of it before handing the
            // error up.
            await rollbackFailedStart()
            throw error
        }
    }

    private func startCapturing(
        title: String,
        calendarEventID: String?,
        calendarEventOccurrenceStart: Date?,
        kind: MeetingKind,
        context: ModelContext
    ) async throws {
        try await TranscriptionEngine.ensureModel()

        let meeting = Meeting(title: title, calendarEventID: calendarEventID)
        meeting.kind = kind
        // Both call sites (MeetingListView, MenuBarView) pass a calendar event's own
        // title verbatim when one is offered, and only fall back to the timestamped
        // placeholder ("Meeting <date, time>" / "Direction — <date, time>") when
        // there isn't one — so "no calendar event" and "this title is the
        // placeholder" are the same condition here. See `Meeting.isTitleAutomatic`.
        meeting.isTitleAutomatic = calendarEventID == nil
        // Start the roster at just your own voice: you're the one person guaranteed to
        // be here, and priming anyone else by default spends slots on people who may
        // not be. Left nil when no voice is marked "me", which keeps the old
        // everyone-enrolled behaviour.
        if let me = SpeakerLabeling.allEnrolled(context: context).first(where: \.isMe) {
            meeting.participantNames = [me.name]
        }
        // Not inserted yet — see the insert right before `state = .recording`
        // below for why. `self.meeting` is a plain Swift reference to an object
        // this `context` doesn't know about yet, which is exactly the point:
        // setting it can't touch disk. The rest of this setup only ever mutates
        // this local `meeting` or reads it back through `self.meeting`, on this
        // same actor, so nothing here needs it context-attached.
        self.meeting = meeting
        self.calendarEventOccurrenceStart = calendarEventOccurrenceStart
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
        // Read fresh at every start, not cached on the session: a change made in the
        // recording controls between meetings should take effect on the next one without
        // requiring a relaunch. Both channels start regardless of what this returns —
        // `RecordingMode` only ever decides the mic's echo cancellation.
        try micCapture.start(mode: .current)
        try systemTap.start()

        // Inserted only now, not when `meeting` was created above: everything
        // since then can still throw (either engine's `start()`, either capture
        // source's `start()`), and `start()`'s catch block unwinds all of it
        // through `rollbackFailedStart` on any of those.
        //
        // This has to be the *insert* that's deferred, not just the `save()` below
        // — `context` is the environment's `ModelContext` (every call site reaches
        // `start(context:)` through `@Environment(\.modelContext)` or
        // `ModelContainer.mainContext`, neither of which this app ever opts out of
        // SwiftData's default `autosaveEnabled = true` for; contrast
        // `MeetingQueryService.makeContext()` in CheerioKit, which sets
        // `autosaveEnabled = false` explicitly because *that* context must never
        // write on its own). Inserting early and only deferring the explicit save
        // still leaves the meeting sitting in this autosaving context's pending
        // changes across every `await` between here and there — any of which can
        // let the run loop service something that trips autosave before this
        // function ever calls `save()` itself. Deferring the insert closes that
        // gap outright: there's nothing in `context`'s pending changes for
        // autosave to act on until this line runs, and nothing suspends between
        // this line and the explicit `save()` two lines down, so no interleaved
        // event gets a chance to write an incomplete recording to disk before this
        // function decides to.
        //
        // `stableID` is read here rather than left to backfill lazily, so the row
        // that lands on disk already carries the same identifier
        // `fireTranscriptReadyCallback` will hand out later — a reader that saw
        // this meeting mid-call and one that sees it after `stop()` need to agree
        // it's the same meeting.
        context.insert(meeting)
        _ = meeting.stableID
        do {
            try context.save()
        } catch {
            // Best-effort, like every checkpoint below: a failed save here doesn't
            // stop the recording, it only means a reader won't see this meeting
            // until the next one succeeds — at worst `stop()`'s own save.
            log.error("Couldn't persist meeting at recording start: \(error)")
        }
        // Started only now too: a checkpoint firing any earlier has nothing
        // inserted yet to add to, and — if it fired between the insert and the
        // save just above — would save a meeting with no `stableID` at all,
        // defeating the save's entire point.
        startCheckpointing(context: context)

        state = .recording
        log.info("Recording started: \(title, privacy: .public)")
        // Withdraws any pending "record it?" offer immediately, rather than leaving
        // one sitting in the system's queue until `NotificationService`'s 5-minute
        // reconcile loop happens to get to it — which, if a request is close enough
        // to its fire time, can lose that race. See
        // `NotificationService.recordingDidStart()` for the rest of the reasoning.
        NotificationService.shared.recordingDidStart()
    }

    /// Starts the periodic save that makes ``handle(_:context:)``'s inserts visible
    /// to a second process, on ``checkpointInterval``'s cadence for as long as this
    /// task runs — cancelled by ``stop(context:)``, which saves explicitly from
    /// that point on. ``rollbackFailedStart()`` also cancels it defensively, but
    /// can never actually find it running: this is the last thing `startCapturing`
    /// calls before nothing further can throw, so a rollback never happens once
    /// this has.
    private func startCheckpointing(context: ModelContext) {
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkpointInterval)
                guard !Task.isCancelled else { return }
                self?.checkpoint(context: context)
            }
        }
    }

    /// One checkpoint save. `hasChanges` skips the common case of a quiet couple of
    /// seconds where nothing new finalized, so this doesn't touch disk on a fixed
    /// timer regardless of whether there's anything to write.
    private func checkpoint(context: ModelContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            log.error("Checkpoint save failed: \(error)")
        }
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
    ///
    /// No `ModelContext` involved, and deliberately so: `startCapturing` only ever
    /// inserts the meeting once nothing between there and `state = .recording` can
    /// still throw, so reaching this rollback means it was never inserted at all —
    /// there is nothing in any context to delete or to undo with a save.
    ///
    /// `consumerTasks` are cancelled and `meeting` is cleared *before* this
    /// function's first `await`, not after: if `micCapture.start()` succeeded but
    /// `systemTap.start()` then threw, the mic side has queued audio, and
    /// `micEngine?.stop()` just below deliberately finalizes and emits whatever it
    /// queued — the same path a real final line takes. Left running, that update
    /// would reach `handle`, which sets `segment.meeting = meeting` and inserts
    /// the segment — implicitly cascade-inserting `meeting` into the (autosaving)
    /// context on the way, out from under a recording this function exists
    /// specifically to undo. Clearing `meeting` first means `handle` finds nothing
    /// to attach a segment to even if a stray update still arrives after the
    /// tasks are cancelled but before they've actually stopped; `handle`'s own
    /// `state` guard is the second, independent line against the same race.
    private func rollbackFailedStart() async {
        let audioDirectory = meeting?.audioDirectory
        consumerTasks.forEach { $0.cancel() }
        consumerTasks = []
        meeting = nil

        micCapture?.stop()
        systemTap?.stop()
        try? await micEngine?.stop()
        try? await systemEngine?.stop()
        checkpointTask?.cancel()
        checkpointTask = nil
        await recorder?.finish()

        if let audioDirectory {
            try? AudioStorage.removeDirectory(atRelativePath: audioDirectory)
        }

        micEngine = nil
        systemEngine = nil
        micCapture = nil
        systemTap = nil
        recorder = nil
        calendarEventOccurrenceStart = nil
        startedAt = nil
        liveLines = []
        volatileLine = nil
        state = .idle
        log.error("Recording failed to start; rolled back")
    }

    private func handle(_ update: TranscriptionUpdate, context: ModelContext) {
        // A final update can still arrive after capture has stopped — either the
        // ordinary drain in `stop()` (`.finishing`, which must keep working: it's
        // the tail of a real transcript) or the failed-start race
        // `rollbackFailedStart()` guards against on its side (`.preparingModel`,
        // by the time anything reaches here). Recording proper and draining its
        // tail are the only states a segment is ever real progress on; anything
        // else is exactly the update this guard exists to drop.
        guard state == .recording || state == .finishing else { return }
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
        // From here on this function saves explicitly at each step below — the
        // periodic checkpoint has nothing left to do and would only race those
        // saves, most of which need to run after work (diarization, enhancement)
        // that a save on a two-second timer can't wait for.
        checkpointTask?.cancel()
        checkpointTask = nil
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

            // Same readiness point as the callback below, one step earlier: after
            // diarization and enhancement (so the excerpt this reads carries
            // speaker labels), before the save and the callback (so both carry
            // whatever title comes out of this, not the timestamp it started
            // with). Gated on `shouldAutoTitle` so a calendar title or an
            // in-meeting rename (RecordingView) is never a candidate.
            if meeting.shouldAutoTitle {
                await autoTitle(meeting: meeting, context: context)
            }
            // Re-synced here, not just once above and once at the very end: the
            // callback below builds its `MeetingExport` from `meeting` as saved by
            // the line right after this one, and diarization and enhancement — both
            // awaits — sit between the first copy and this point. Skipping this one
            // would let the callback ship a `roughNotes` that's stale relative to
            // the `enhancedNotes` next to it in the same payload, which read the
            // live property directly a few lines up. The copy at the end of this
            // function is still needed too, for anything typed after this point but
            // before `meeting` goes nil.
            meeting.roughNotes = roughNotes
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

            // Same definition of "ready" as the callback above, and deliberately
            // *after* it: this only enqueues a banner, and nothing about a
            // notification may delay, gate, or fail the callback that external
            // tooling waits on. It returns immediately — see `notifyNotesReady`,
            // which does the posting on its own task — and suppresses itself when the
            // app is already on screen, since by the time this returns the window has
            // selected the finished meeting anyway.
            //
            // `stableID` is safe to read here: the callback above persisted it, and
            // on the path where that save failed the id still exists in memory, so
            // the notification is at worst pointing at a meeting whose id a crash
            // before the next autosave would change.
            NotificationService.shared.notifyNotesReady(title: meeting.title, meetingID: meeting.stableID)
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
        // A second copy, not a redundant one: `MeetingDetailView` binds its editor
        // straight to `roughNotes` here for as long as `meeting == self.meeting`
        // (see that view), which is true for this whole function, not just up to
        // the copy above. Diarization and enhancement between here and there take
        // real wall-clock time, so a keystroke landing in that window would
        // otherwise update this property and then be silently dropped the moment
        // `meeting` goes nil below and the view's binding switches back to
        // whatever the model held as of the *first* copy.
        meeting?.roughNotes = roughNotes
        lastFinishedMeeting = meeting
        lastFinishedMeetingOccurrenceStart = calendarEventOccurrenceStart
        meeting = nil
        calendarEventOccurrenceStart = nil
        state = .idle
    }

    /// See the call site in ``stop(context:)`` for exactly which point in the
    /// pipeline this is — this function only builds the export and hands it to
    /// the runner, it doesn't decide when "ready" is.
    private func fireTranscriptReadyCallback(for meeting: Meeting, context: ModelContext) {
        // Touch `stableID` and save *before* building the export, not as part of it.
        // `Meeting.export` reads `stableID`, which backfills `uuid` on a meeting
        // recorded before that field existed — and the save above already happened,
        // so that backfill would otherwise sit unsaved in memory. The callback is
        // about to hand that UUID to an external consumer as CHEERIO_MEETING_ID; if
        // the app quit before the next autosave, the meeting would come back with a
        // *different* ID and the consumer's reference would point at nothing.
        // Persist it first, then publish it.
        _ = meeting.stableID
        do {
            try context.save()
        } catch {
            // And if that save fails, don't fire at all. A callback carrying an ID
            // that may not survive a relaunch is worse than no callback: the
            // consumer files away a reference that quietly points at nothing,
            // whereas a callback that never ran is a visible no-op the user can
            // retry from Settings.
            log.error("Couldn't persist the meeting ID for the transcript-ready callback; not firing: \(error)")
            return
        }

        let ownerNames = SpeakerLabeling.ownerNames(context: context)
        TranscriptReadyRunner.fireIfNeeded(export: meeting.export(ownerNames: ownerNames))
    }

    /// Generates and applies a title for a meeting that's still on its placeholder
    /// — issue #32. Best-effort: a title is a nicety, not something worth
    /// stranding the recording in `.finishing` over, so any failure is logged and
    /// the timestamp title stands.
    private func autoTitle(meeting: Meeting, context: ModelContext) async {
        do {
            let generator = TitleGenerator()
            let title = try await generator.generateTitle(
                transcript: meeting.transcriptText,
                recentTitles: recentTitles(excluding: meeting, context: context)
            )
            guard !title.isEmpty else { return }
            // Re-check right before applying, not just at the top of this function:
            // `generateTitle` suspends for the length of a model call, and the main
            // actor is free to run a user rename on `meeting` while we're waiting on
            // it. If that happened, `shouldAutoTitle` is now false and applying this
            // result would silently overwrite the title the user just typed — the
            // manual-title-wins invariant (``Meeting/rename(to:)``) has to hold across
            // the suspension, not just before it.
            guard meeting.shouldAutoTitle else { return }
            meeting.applyGeneratedTitle(title)
        } catch {
            log.error("Auto-title failed: \(error)")
        }
    }

    /// The library's most recent titles, for ``TitleGenerator``'s uniqueness
    /// constraint — the meeting being titled is excluded, since comparing its
    /// still-placeholder title against itself would only weaken the constraint.
    private func recentTitles(excluding meeting: Meeting, context: ModelContext, limit: Int = 10) -> [String] {
        var descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        // One extra: `meeting` itself is already in the store (inserted at start)
        // and usually sorts first, so the window needs room to drop it and still
        // return `limit` others.
        descriptor.fetchLimit = limit + 1
        let meetings = (try? context.fetch(descriptor)) ?? []
        return
            meetings
            .filter { $0.persistentModelID != meeting.persistentModelID }
            .prefix(limit)
            .map(\.title)
    }
}
