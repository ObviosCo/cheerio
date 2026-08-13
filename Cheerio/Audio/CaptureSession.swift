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
    /// `Equatable` so `MeetingDetailView` (which owns the meeting's audio
    /// player) can react to a transition with `.onChange(of:)` — it has to know
    /// when a recording *starts*, not just poll whether one is in progress,
    /// since playback that was already running has to be actively paused, not
    /// merely left un-resumable.
    enum State: Equatable {
        case idle
        case preparingModel
        case recording
        /// Capture has fully stopped and the transcript is saved, but processing
        /// (diarization, enhancement, the callback) hasn't been claimed yet — the
        /// post-meeting holding state, issue #136. The user can still edit rough
        /// notes, the meeting kind, and the callback controls; ``confirmProcessing(context:)``
        /// or the grace deadline (``holdDeadline``) moves on to `.finishing`.
        /// Never entered when `ProcessingHoldDuration` is `.off` or the recording
        /// is a directive — those go straight from `.recording` to `.finishing`,
        /// exactly as every recording did before this state existed.
        case holding
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

    /// Meetings with a mutation in flight — the processing pipeline itself (which
    /// marks the meeting for the duration of ``process(meeting:plan:context:)``),
    /// launch recovery's claim-to-pipeline stretch, and `MeetingDetailView`'s
    /// manual "Re-identify speakers" button.
    ///
    /// Reference counts, not a set, because two of those can legitimately overlap
    /// on one meeting — launch recovery runs while `state` is `.idle`, exactly
    /// when the detail view's re-identify button is live — and set semantics
    /// would let whichever pass finishes first unmark the meeting while the other
    /// is still mutating it, re-enabling deletion, retention, and update checks
    /// early. (The UI also refuses to *start* the overlapping pass — see
    /// ``isProcessing(_:)`` — but the count is what keeps the marks honest even
    /// if a new caller forgets that check.)
    ///
    /// Keyed by `persistentModelID`, not the `Meeting` itself, on purpose — this is
    /// the one piece of shared state every delete affordance consults, and holding
    /// a `Meeting` here past a delete would be exactly the "still holding a model
    /// SwiftData just removed" bug this exists to prevent.
    ///
    /// This is the app's one shared `@Observable`, which is why a cross-cutting
    /// concern like "is anything mutating this meeting right now" lives here rather
    /// than on a purpose-built type — the alternative costs a new object threaded
    /// into every scene in `CheerioApp` for one small dictionary.
    private var processingMeetingIDs: [PersistentIdentifier: Int] = [:]

    /// Marks `meeting` as having a background mutation in flight. Call before the
    /// first suspension point of whatever's about to `await` its way through
    /// changing it, and unconditionally clear with ``endProcessing(_:)`` in a
    /// `defer` — on the success path and the failure path alike, or a thrown error
    /// leaves the meeting permanently undeletable.
    func beginProcessing(_ meeting: Meeting) {
        processingMeetingIDs[meeting.persistentModelID, default: 0] += 1
    }

    func endProcessing(_ meeting: Meeting) {
        let id = meeting.persistentModelID
        guard let count = processingMeetingIDs[id] else { return }
        processingMeetingIDs[id] = count > 1 ? count - 1 : nil
    }

    /// Whether some pass currently has `meeting` mid-mutation. The detail view's
    /// re-identify action checks this before starting (and disables its button on
    /// it), so two diarization passes never rewrite the same meeting's labels
    /// concurrently — launch recovery of a held meeting runs at `.idle`, exactly
    /// when that button is otherwise live.
    ///
    /// The session's own ``meeting`` counts as busy for its whole lifetime, not
    /// just once the pipeline populates the marks: its row is in the store (and
    /// so in the sidebar) from recording start, but while recording its CAFs are
    /// still being written under any pass that would read them, and while held
    /// the grace deadline can start the pipeline at any moment — a re-identify
    /// begun seconds earlier would then run concurrently with it over the same
    /// segments.
    func isProcessing(_ meeting: Meeting) -> Bool {
        meeting == self.meeting || processingMeetingIDs[meeting.persistentModelID] != nil
    }

    /// The marked meetings, for `AudioRetentionService.purge`'s exclusion: a purge
    /// can run mid-pipeline (Settings' "Delete audio now", the launch sweep), and
    /// diarization is still reading exactly the CAF files it would remove.
    var meetingIDsBeingProcessed: Set<PersistentIdentifier> {
        Set(processingMeetingIDs.keys)
    }

    /// Whether any meeting is mid-pipeline outside the live capture flow — launch
    /// recovery of a held meeting, or a manual re-identify pass. `UpdatePolicy`
    /// reads this alongside ``state``: recovery runs diarization and enhancement
    /// while `state` is still `.idle`, and an update check admitted on the
    /// strength of `.idle` alone would overlap that processing — exactly what the
    /// keep-updates-out-of-the-way gate exists to prevent for the ordinary
    /// `.finishing` path.
    var isProcessingInBackground: Bool {
        !processingMeetingIDs.isEmpty
    }

    /// Whether every delete affordance should treat `meeting` as safe to remove
    /// right now: not the meeting actively recording (``meeting`` stays set through
    /// `.finishing`, so this covers that phase too), and nothing else has it
    /// mid-mutation per ``beginProcessing(_:)``.
    ///
    /// A disabled button rather than cancel-and-await, for a first pass — see the
    /// call sites in `MeetingListView` and `MeetingDetailView`.
    func canDelete(_ meeting: Meeting) -> Bool {
        meeting != self.meeting && processingMeetingIDs[meeting.persistentModelID] == nil
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
    /// Flushes pending changes to disk on ``checkpointInterval``'s cadence — see
    /// ``startCheckpointing(context:)``. Armed twice per meeting that holds:
    /// while recording (bounding staleness for finalized transcript segments,
    /// cancelled in ``stop(context:)``, which takes over saving explicitly) and
    /// again while `.holding` (bounding it for hold edits, cancelled by
    /// ``completeHold(context:)`` once the claim save supersedes it). Also
    /// cancelled defensively in ``rollbackFailedStart()``, which in practice
    /// never finds it running.
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

    /// When the holding state auto-processes, for the countdown readouts. Moves
    /// later on every ``recordHoldActivity()``; nil outside `.holding`.
    private(set) var holdDeadline: Date?
    /// The grace-period arithmetic behind ``holdDeadline`` — `CheerioKit` owns the
    /// math (tested there), this session only owns the clock that acts on it.
    private var holdWindow: ProcessingHoldWindow?
    /// Sleeps until ``holdDeadline`` and claims processing if nothing else has —
    /// see ``beginHolding(gracePeriod:context:)`` for why it re-checks on waking
    /// instead of trusting one sleep.
    private var holdTask: Task<Void, Never>?

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
        try micCapture.start()
        try systemTap.start()
        // Armed only with both channels up: had `systemTap.start()` thrown,
        // `rollbackFailedStart()` would stop a mic that ran for under a second
        // during which nobody was asked to speak, and an unarmed watch stays
        // quiet instead of logging a TCC diagnosis for a recording that never
        // existed.
        micCapture.armSilenceVerdict()

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

    /// Starts the periodic save that bounds how stale the on-disk row can be:
    /// while recording, it makes ``handle(_:context:)``'s inserts visible to a
    /// second process (cancelled by ``stop(context:)``, which saves explicitly
    /// from that point on); while `.holding`, re-armed by
    /// ``beginHolding(gracePeriod:context:)``, it does the same for
    /// ``recordHoldActivity()``'s edits, which crash recovery reads off the row.
    /// ``rollbackFailedStart()`` also cancels it defensively, but can never
    /// actually find it running: in the recording case this is the last thing
    /// `startCapturing` calls before nothing further can throw, so a rollback
    /// never happens once this has.
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

    /// Stops capture and finalizes transcription, then either processes the
    /// meeting immediately (holding off, or a directive — the pre-#136 behavior,
    /// unchanged) or parks it in `.holding` for the user to add rough notes and
    /// set the processing controls first.
    func stop(context: ModelContext) async {
        guard state == .recording else { return }
        state = .finishing

        micCapture?.stop()
        systemTap?.stop()
        try? await micEngine?.stop()
        try? await systemEngine?.stop()
        // From here on, saves are explicit at each step — the periodic checkpoint
        // has nothing left to do and would only race those saves, most of which
        // need to run after work (diarization, enhancement) that a save on a
        // two-second timer can't wait for.
        checkpointTask?.cancel()
        checkpointTask = nil
        await recorder?.finish()
        // Drain, don't cancel. Each engine's `stop()` finishes its results stream, so
        // these consumers end on their own once they've handed over every update —
        // and it's the final updates of the meeting that are still in flight here.
        // Cancelling dropped them, losing the tail of the transcript that the
        // summarizer then never saw.
        await drainConsumers()
        // Capture is over for good whichever branch below runs — releasing the
        // engines and taps here, rather than at `.idle`, is what keeps the holding
        // state from sitting on a dead audio stack for minutes.
        micEngine = nil
        systemEngine = nil
        micCapture = nil
        systemTap = nil
        recorder = nil

        guard let meeting else {
            concludeSession(context: context)
            return
        }
        meeting.endedAt = .now
        meeting.roughNotes = roughNotes

        let holdDuration = ProcessingHoldDuration.current
        if let gracePeriod = holdDuration.gracePeriod, holdDuration.applies(to: meeting.kind) {
            // The plan and the finished transcript are persisted *before* the
            // holding state is entered, because the plan on disk is the whole
            // recovery contract: a quit or crash from here on leaves a row that
            // `resumeInterruptedProcessing` recognizes and processes next launch.
            meeting.pendingProcessingPlan = ProcessingPlan.makeDefault(for: meeting.kind)
            do {
                try context.save()
                beginHolding(gracePeriod: gracePeriod, context: context)
                return
            } catch {
                // Not best-effort like other saves on this path: the hold's
                // crash-safety rests entirely on that marker being on disk before
                // `.holding` is entered — held with nothing persisted, a quit
                // would strand the meeting unprocessed forever. So no marker, no
                // hold: fall through to processing immediately, which needs no
                // marker to be safe. Losing the review window costs a
                // convenience; risking the meeting would cost the meeting. The
                // plan is cleared first so a *later* autosave can't land the
                // marker mid-processing and set up next launch to process — and
                // fire the callback for — this meeting a second time.
                meeting.pendingProcessingPlan = nil
                log.error("Couldn't persist the processing hold; processing immediately instead: \(error)")
            }
        }

        await process(meeting: meeting, plan: nil, context: context)
        concludeSession(context: context)
    }

    /// Enters `.holding` and starts the clock that ends it. The task sleeps to the
    /// deadline and then *re-checks* rather than firing blind: ``recordHoldActivity()``
    /// pushes ``holdDeadline`` while this sleeps, so waking at the original
    /// deadline and finding a later one is the normal case for someone actively
    /// typing — looping until the deadline it wakes at is still the real one is
    /// what makes an extension actually extend.
    private func beginHolding(gracePeriod: TimeInterval, context: ModelContext) {
        let window = ProcessingHoldWindow(startedAt: .now, gracePeriod: gracePeriod)
        holdWindow = window
        holdDeadline = window.deadline
        state = .holding
        // The same periodic save that bounds staleness for transcript segments
        // while recording bounds it for hold edits here: `recordHoldActivity()`
        // only mutates the autosaving context, and autosave's timing carries no
        // guarantee — a crash mid-hold recovers from the row, so notes and plan
        // edits must reach it on a cadence, not at autosave's leisure. Cancelled
        // by `completeHold` once the claim save (which supersedes it) lands.
        startCheckpointing(context: context)
        holdTask = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled, self.state == .holding,
                    let deadline = self.holdDeadline
                else { return }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    // `cancellingCountdown: false`, because *this task is* the
                    // countdown: `completeHold` runs the whole pipeline before
                    // returning here, and cancelling the current task first would
                    // hand diarization and the language model a pre-cancelled
                    // context — cancellation-aware work would abort *after* the
                    // plan was already durably cleared, leaving every auto-timed
                    // meeting transcript-only. A successful claim leaves
                    // `.holding`, so the guard above ends the loop instead.
                    await self.completeHold(context: context, cancellingCountdown: false)
                    // A *failed* claim stayed held and pushed the deadline out a
                    // full window (see `completeHold`), so looping here sleeps
                    // toward the retry rather than spinning against a failing
                    // save.
                    continue
                }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    /// The user's explicit "process now" from the holding state. Also the only
    /// public way out of `.holding` — the other exit is the grace deadline, which
    /// takes the same path through ``completeHold(context:cancellingCountdown:)``.
    func confirmProcessing(context: ModelContext) async {
        await completeHold(context: context, cancellingCountdown: true)
    }

    /// An edit landed in the holding UI — rough notes, kind, callback controls —
    /// so the grace window restarts (it measures idle time, not total time; see
    /// ``ProcessingHoldWindow/recordActivity(at:)``) and the notes are re-synced
    /// onto the meeting. That sync is what keeps a quit mid-hold from losing
    /// anything typed *during* the hold: recovery reads `meeting.roughNotes` off
    /// the row, never this session's live property, which dies with the process.
    /// Getting the sync to *disk* is the checkpoint loop's job — re-armed for the
    /// hold by ``beginHolding(gracePeriod:context:)``, because autosave's timing
    /// carries no guarantee and a crash recovers only what actually landed.
    func recordHoldActivity() {
        guard state == .holding else { return }
        holdWindow?.recordActivity(at: .now)
        holdDeadline = holdWindow?.deadline
        meeting?.roughNotes = roughNotes
    }

    /// The holding state's callback toggle, routed through the session (rather
    /// than the view binding the meeting's plan directly) so every edit also
    /// counts as activity for the grace window. False when nothing is held, which
    /// no visible control ever reads — the holding UI only exists in `.holding`.
    var holdRunsCallback: Bool {
        get { meeting?.pendingProcessingPlan?.runCallback ?? false }
        set {
            guard state == .holding else { return }
            meeting?.pendingProcessingPlan?.runCallback = newValue
            recordHoldActivity()
        }
    }

    /// See ``holdRunsCallback`` — same routing, for which trigger the callback
    /// runs (issue #137). The getter resolves through the *same* fallback the
    /// fire decision uses (`TranscriptCallbackSettings.trigger(for:)`) rather
    /// than returning the plan's raw id: Settings can delete the chosen trigger
    /// mid-hold, and a raw stale id would leave the picker showing no selection
    /// while the default is what would actually fire — the UI must show the
    /// effective choice, not the recorded one. Before anything is chosen it
    /// reads as the default trigger for the same reason: the picker opens on
    /// what will actually run. Once set, the concrete id rides the plan to
    /// processing (and through a crash, like every other plan field).
    var holdTriggerID: UUID? {
        get { TranscriptCallbackSettings.trigger(for: meeting?.pendingProcessingPlan)?.id }
        set {
            guard state == .holding else { return }
            meeting?.pendingProcessingPlan?.triggerID = newValue
            recordHoldActivity()
        }
    }

    /// See ``holdRunsCallback`` — same routing, for the per-meeting prompt.
    var holdCallbackPrompt: String {
        get { meeting?.pendingProcessingPlan?.callbackPrompt ?? "" }
        set {
            guard state == .holding else { return }
            meeting?.pendingProcessingPlan?.callbackPrompt = newValue
            recordHoldActivity()
        }
    }

    /// See ``holdRunsCallback`` — same routing, for the meeting kind. This window
    /// is exactly when changing kind is cheap: no notes exist yet to go stale
    /// (the regeneration concern ``Meeting/toggleKind()`` documents), and every
    /// downstream consumer of kind — the summarizer's future prompt seam, the
    /// callback scope, the export — reads it after this.
    var holdKind: MeetingKind {
        get { meeting?.kind ?? .meeting }
        set {
            guard state == .holding else { return }
            meeting?.kind = newValue
            recordHoldActivity()
        }
    }

    /// Claims processing for the held meeting — from the user's confirm or the
    /// grace deadline, whichever gets here first; the `state` guard makes the
    /// loser a no-op, and nothing before `state = .finishing` suspends (the claim
    /// save is synchronous), so the race can't interleave.
    ///
    /// `cancellingCountdown` says whether ``holdTask`` is somebody *else* who
    /// needs waking (the confirm path — its sleep should end now, not at the old
    /// deadline) or the very task running this function (the expiry path), which
    /// must not be cancelled: the pipeline below runs inside it, and a
    /// self-cancel would pre-cancel diarization and the language model after the
    /// plan was already durably cleared. Either way the countdown loop exits on
    /// its own state guard once `.holding` is left; the flag only controls
    /// whether a signal is sent.
    private func completeHold(context: ModelContext, cancellingCountdown: Bool) async {
        guard state == .holding, let meeting else { return }

        // Claiming = reading the plan and clearing it off the row, *durably*,
        // before any work runs. That ordering makes processing at-most-once: a
        // crash mid-processing finds no plan on disk and leaves the meeting
        // transcript-only — the same outcome a crash mid-`.finishing` has always
        // had — never a second processing pass, and never a callback fired twice,
        // on relaunch.
        let plan = meeting.pendingProcessingPlan
        meeting.pendingProcessingPlan = nil
        meeting.roughNotes = roughNotes
        do {
            try context.save()
        } catch {
            // The claim didn't land, so processing doesn't start. A meeting that
            // stays visibly held — the deadline retries a window from now, and
            // "Process Now" stays clickable — beats one that processes now and
            // may process (and fire its callback) again after a crash; and if
            // the save never recovers, a quit still leaves the persisted plan
            // for the next launch, so the meeting can't be stranded. Restore the
            // plan so the row, the UI, and a later checkpoint save all agree.
            meeting.pendingProcessingPlan = plan
            holdWindow?.recordActivity(at: .now)
            holdDeadline = holdWindow?.deadline
            log.error("Couldn't claim the held meeting for processing; staying held: \(error)")
            return
        }

        if cancellingCountdown {
            holdTask?.cancel()
        }
        holdTask = nil
        holdWindow = nil
        holdDeadline = nil
        checkpointTask?.cancel()
        checkpointTask = nil
        state = .finishing

        await process(meeting: meeting, plan: plan, context: context)
        concludeSession(context: context)
    }

    /// Diarization → enhancement → auto-title → save → callback → notification:
    /// the one processing pipeline, shared by the zero-touch stop path, the
    /// holding state's exit, and launch recovery of a hold a previous run left
    /// behind. `plan` is the holding state's decisions when there was one; nil is
    /// the zero-touch path, which defers to the global callback settings exactly
    /// as before.
    private func process(meeting: Meeting, plan: ProcessingPlan?, context: ModelContext) async {
        // Marked for the whole pipeline, on every path: once the plan is cleared
        // (or was never set — the zero-touch path), nothing on the *row* says
        // this meeting's audio is still needed, and a retention purge is free to
        // run during any await below — Settings' "Delete audio now", the launch
        // sweep racing recovery. This mark is what
        // `AudioRetentionService.purge`'s exclusion reads to keep the CAFs alive
        // until diarization has actually consumed them. Reference-counted, so
        // recovery's own outer mark nesting over this one is fine.
        beginProcessing(meeting)
        defer { endProcessing(meeting) }

        // First, before anything consumes segments: mark mic-channel lines that
        // are really the far end heard through the speakers (issue #5), so
        // diarization doesn't label them, the summarizer's transcript doesn't
        // repeat them, and the export doesn't ship them mis-attributed. Text-only
        // and synchronous — no audio is read and nothing here can fail; the marks
        // ride along on the pipeline's later saves.
        meeting.markBleedSegments()

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
                roughNotes: currentRoughNotes(for: meeting),
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
        // Re-synced here, not just at the top of the stop path: the callback below
        // builds its `MeetingExport` from `meeting` as saved by the line right
        // after this one, and diarization and enhancement — both awaits — sit
        // between the earlier copy and this point, during which the notes editor
        // (live through `.finishing`) can still run a keystroke's binding setter.
        //
        // This is the *last* copy that's needed, not just the latest: from here
        // to the caller's `meeting = nil`, nothing suspends —
        // `fireTranscriptReadyCallback`, `notifyNotesReady`, and
        // `AudioRetentionService.purge` are all synchronous, and `CaptureSession`
        // is `@MainActor` — so nothing else can run a keystroke's binding setter
        // in between. A copy repeated at the end would be dead code today. If a
        // future `await` lands anywhere in that stretch, *that's* what needs a
        // copy after it, not a blind one at the bottom.
        if meeting == self.meeting {
            meeting.roughNotes = roughNotes
        }
        try? context.save()

        // The transcript is "ready" — issue #26's callback contract — right
        // here, and nowhere else: capture has stopped, diarization has run
        // (`catch` above notwithstanding — a failed pass still leaves the
        // channel-only labels, which is what a callback fired any earlier
        // would have shipped anyway), and enhancement has run or conclusively
        // failed. Firing before this point would hand the callback worse
        // speaker attribution than the app itself ends up showing, and labels
        // are exactly what the owner-attributed action items depend on. The
        // holding state moved this point later still, deliberately — see issue
        // #136 — but never earlier.
        fireTranscriptReadyCallback(for: meeting, plan: plan, context: context)

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

    /// The rough notes ``process(meeting:plan:context:)`` should feed the
    /// summarizer: the session's live property for the meeting this session is
    /// actively finishing (the editor stays bound to it through `.finishing`, so
    /// it's fresher than the row), and the persisted row for a recovered meeting,
    /// whose editing surface died with the run that held it.
    private func currentRoughNotes(for meeting: Meeting) -> String {
        meeting == self.meeting ? roughNotes : meeting.roughNotes
    }

    /// The tail every processing exit shares: the retention sweep, then handing
    /// the session back to `.idle` with ``lastFinishedMeeting`` pointing at what
    /// just finished.
    private func concludeSession(context: ModelContext) {
        // Applies "Don't keep audio" immediately, and sweeps anything that aged out
        // while the app stayed open. The meeting that just finished is *not*
        // excluded — its pipeline is done, so this is exactly the purge that
        // should reach it — only meetings some other pass (launch recovery) still
        // has mid-flight are.
        do {
            try AudioRetentionService.purge(
                retention: .current, context: context, excludingMeetingIDs: meetingIDsBeingProcessed)
        } catch {
            log.error("Audio retention purge failed: \(error)")
        }

        lastFinishedMeeting = meeting
        lastFinishedMeetingOccurrenceStart = calendarEventOccurrenceStart
        meeting = nil
        calendarEventOccurrenceStart = nil
        state = .idle
    }

    /// Processes any meeting a previous run left in the holding state — a quit or
    /// crash mid-hold. Called once, from `CheerioApp.init()`'s launch task, after
    /// `StorageMigration.closeAbandonedRecordings` has run.
    ///
    /// The choice this encodes: recovery *processes*, it never re-opens the
    /// holding window. The plan persisted at hold entry (plus whatever notes and
    /// kind edits autosave carried to disk) is treated as the user's final word —
    /// including their callback decision, which is honored as saved. Re-offering
    /// the hold on launch would mean a meeting whose owner never relaunches stays
    /// un-summarized indefinitely, which is exactly the "stuck meeting" this
    /// state machine promises can't happen; processing with the saved inputs
    /// loses nothing except the chance to keep editing, which the quit already
    /// spent.
    ///
    /// Doesn't touch session state: this runs meetings that aren't ``meeting``,
    /// concurrently with whatever the session might start doing, and marks each
    /// one with ``beginProcessing(_:)`` so delete affordances stay honest.
    func resumeInterruptedProcessing(context: ModelContext) async {
        let pending: [Meeting]
        do {
            pending = try Meeting.awaitingProcessing(in: context)
        } catch {
            log.error("Couldn't look for interrupted processing: \(error)")
            return
        }
        for meeting in pending {
            // Can't be this session's live meeting at launch; kept as a guard
            // because processing the meeting someone is talking into would be
            // unrecoverable, and launch ordering is the caller's detail.
            guard meeting != self.meeting else { continue }
            beginProcessing(meeting)
            // Per-iteration, not function exit: a `defer` runs when its enclosing
            // *scope* ends, and a loop body is one — Swift, unlike Go. So each
            // meeting's mark is already cleared (on `continue` too) by the time
            // the post-loop sweep below reads `meetingIDsBeingProcessed`, which
            // is what lets that sweep actually reach the meetings it exists for.
            defer { endProcessing(meeting) }
            // Same claim discipline as `completeHold`, for the same reason: the
            // cleared plan must be durable before any work runs, or a crash
            // mid-recovery would leave the plan on the row and the launch after
            // this one would process — and fire the callback for — the same
            // meeting again. If the claim can't be saved, the row is left intact
            // for a future launch instead: deferred processing beats double
            // processing.
            let plan = meeting.pendingProcessingPlan
            meeting.pendingProcessingPlan = nil
            do {
                try context.save()
            } catch {
                meeting.pendingProcessingPlan = plan
                log.error("Couldn't claim a held meeting for recovery; leaving it for the next launch: \(error)")
                continue
            }
            log.notice("Processing a meeting a previous run left holding")
            await process(meeting: meeting, plan: plan, context: context)
        }
        guard !pending.isEmpty else { return }
        // The sweep these meetings were shielded from while held (the pending
        // plan) and while mid-pipeline (the processing mark): with both gone,
        // "Don't keep audio" finally applies to them — deliberately *without*
        // touching the recovery marker, which is exactly what must stay cleared
        // so a crash here can't reprocess. Any meeting still marked (a second
        // recovery pass can't exist, but the exclusion is cheap and uniform)
        // stays skipped.
        do {
            try AudioRetentionService.purge(
                retention: .current, context: context, excludingMeetingIDs: meetingIDsBeingProcessed)
        } catch {
            log.error("Audio retention purge after recovery failed: \(error)")
        }
    }

    /// See the call site in ``process(meeting:plan:context:)`` for exactly which
    /// point in the pipeline this is — this function only builds the export and
    /// hands it to the runner, it doesn't decide when "ready" is.
    private func fireTranscriptReadyCallback(for meeting: Meeting, plan: ProcessingPlan?, context: ModelContext) {
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
        TranscriptReadyRunner.fireIfNeeded(export: meeting.export(ownerNames: ownerNames), plan: plan)
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
