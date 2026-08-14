import CheerioKit
import SwiftData
import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting
    /// Run after this meeting is deleted, so the caller can clear whatever
    /// selection was pointing at it — this view owns no binding to that itself,
    /// since `ContentView` passes it a plain `Meeting`, not a `Binding<Meeting?>`.
    var onDelete: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(CaptureSession.self) private var session
    @Query(sort: \EnrolledSpeaker.enrolledAt) private var enrolled: [EnrolledSpeaker]
    @State private var relabelError: String?
    @State private var isDeleteConfirming = false
    @State private var deleteError: String?
    /// Set from `convertMeetingKind`'s return value — kept separate from
    /// ``relabelError`` and ``deleteError`` so a failed kind flip gets its own
    /// wording instead of borrowing either of theirs.
    @State private var convertError: String?
    /// Collapsed on every open (#104): opening a meeting was showing the transcript
    /// in full alongside everything else, which read as too much at once. No
    /// persistence — collapsed every time is the intended behavior, not a stand-in
    /// for remembering the last state.
    ///
    /// `ScreenshotMode.expandsTranscript` is false in a real launch, so this is
    /// `false` there too — it exists only so the harness's one capture that needs
    /// the transcript visible doesn't have to simulate a click. The initializer
    /// alone isn't enough to keep this collapsed, though: SwiftUI reuses this
    /// view's state across a sidebar selection change rather than recreating it,
    /// so the meeting-keyed `.task` below resets this on every switch — without
    /// that, expanding one meeting's transcript and then selecting another would
    /// open the next one already expanded.
    @State private var isTranscriptExpanded = ScreenshotMode.expandsTranscript
    /// Seeds and opens the shared rename alert (``renameMeetingAlert``) — the same
    /// flow the library list's "Rename" context menu drives, triggered here by the
    /// pencil button next to the title instead of a right click.
    @State private var renamingMeeting: Meeting?
    @State private var renameText = ""
    /// Rough notes render as Markdown once a meeting has ended (#108), with this as
    /// the toggle back to the plain editor. Defaults to the rendered view — "write
    /// it, see it rendered" only reads as delivered if rendered is what greets you
    /// coming back to a meeting, not another editor. Reset to `false` alongside
    /// ``isTranscriptExpanded`` below, for the same reason: this view is reused,
    /// not recreated, across a sidebar selection change.
    @State private var isEditingRoughNotes = false
    /// Owned here, not inside ``MeetingAudioPlayerView``, because two sibling
    /// sections drive the same player: the scrubber controls, and the
    /// transcript's tap-to-seek (#123). Replaced wholesale — teardown, fresh
    /// instance, fresh load — in the meeting-keyed `.task` below, since this
    /// view is reused across a sidebar selection change and one model must
    /// never outlive the meeting whose audio it was loaded from.
    @State private var playerModel = MeetingAudioPlayerModel()
    /// Same as `RecordingView.observedTriggersData`: the raw trigger blob,
    /// observed so ``runTriggerSection`` (its presence, and the menu's rows)
    /// re-renders when Settings edits triggers — the click path re-resolves by
    /// id regardless (`runTrigger(id:)`), so this is about the *list* staying
    /// honest, not about what runs. Read in `body`, never decoded here.
    @AppStorage(TranscriptCallbackSettings.triggersDefaultsKey) private var observedTriggersData: Data?
    /// The channels this meeting could be transcribed again from (#14), refreshed
    /// by the meeting-keyed `.task` below and after a repair. Empty is the common
    /// case: retention purges audio after three days by default, and the
    /// affordance goes with it — same rule as playback and "use as a voice sample".
    @State private var repairProbes: [TranscriptRepair.ChannelProbe] = []
    /// The channels that captured audio and produced no transcript from it — the
    /// prompt, rather than leaving someone to guess which half of their meeting is
    /// missing. Measured off the main actor from the CAF itself, since the capture
    /// source that knew this live is long gone.
    @State private var repairAdvice: [TranscriptionCoverage] = []
    /// What the last repair did, shown until the meeting is switched. Kept separate
    /// from the transcript's own segment count because "37 lines recovered, 2 of
    /// yours kept" is the part that isn't visible by reading the result.
    @State private var repairSummary: String?
    @State private var repairError: String?
    /// Which transcript row's seek affordance is visible. Hover-revealed rather
    /// than always-on: a stamp on every line is exactly the column of numbers
    /// the per-minute timestamps (#130) exist to avoid, and the row's text keeps
    /// `.textSelection(.enabled)`, so the tap target has to be its own control
    /// beside the text, not the line itself.
    @State private var hoveredSegmentID: PersistentIdentifier?

    /// Bleed lines stay persisted but never render: showing the far end's words a
    /// second time under "Me" is the duplication the post-processing marks exist
    /// to remove — see `TranscriptSegment.isBleed`.
    private var sortedSegments: [TranscriptSegment] {
        meeting.segments
            .filter { !$0.isBleed }
            .sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        ScrollView {
            // One rule between every section (#104b): the same boundary
            // `RecordingView` already draws between its header and its panes,
            // applied consistently here instead of leaving some sections
            // touching and others not.
            VStack(alignment: .leading, spacing: Theme.Space.x6) {
                header

                notes

                Divider()
                roughNotes

                if MeetingAudioPlayback.hasPlayableAudio(for: meeting) {
                    Divider()
                    // `.id` resets the view's own scrub-in-progress state on a
                    // meeting switch; the player model's lifetime is the
                    // meeting-keyed `.task` below, not this identity.
                    MeetingAudioPlayerView(model: playerModel)
                        .id(meeting.persistentModelID)
                }

                if meeting.audioDirectory != nil {
                    Divider()
                    HStack(spacing: Theme.Space.x2) {
                        Button {
                            Task { await relabel() }
                        } label: {
                            // A button, not a status readout: this used to flip to
                            // "Identifying speakers…" for the pass it started
                            // itself, which said nothing about the same pass
                            // arriving from launch recovery or the end of a
                            // recording. The header's indicator answers all three
                            // now (issue #173), so the label can stay the action.
                            Label("Re-identify speakers", systemImage: "person.wave.2")
                        }
                        // The session's marks, with no `isRelabeling` beside them:
                        // `relabel()` marks the meeting before its first await, so
                        // this covers its own pass as well as the ones it always
                        // had to — launch recovery of a held meeting runs its
                        // pipeline while the session is `.idle`, exactly when this
                        // view can be showing that meeting, and two diarization
                        // passes rewriting the same labels concurrently is a race
                        // no ordering of their saves makes right.
                        .disabled(session.isProcessing(meeting))
                        Text("Uses the voices enrolled in Settings → Participants.")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }

                if !repairProbes.isEmpty {
                    Divider()
                    retranscribeSection
                }

                // Any configured trigger, not just the default (#137) — pointing
                // a different agent at a finished meeting is also how it gets
                // re-processed through one. `endedCleanly`, not `endedAt != nil`:
                // a crash-abandoned recording gets an `endedAt` backfilled at the
                // next launch without ever running diarization or enhancement,
                // and a held or launch-recovered meeting has one from the moment
                // recording stopped while its pipeline is still owed — offering
                // to hand either partial capture to an agent as "ready" would
                // ship the exact half-processed state the callback contract
                // exists to rule out. (The live meeting reaches this view too; it
                // has no `endedAt` at all.)
                let _ = observedTriggersData
                if meeting.endedCleanly, TranscriptCallbackSettings.hasRunnableTrigger {
                    Divider()
                    runTriggerSection
                }

                Divider()
                MeetingSpeakersSection(meeting: meeting)

                Divider()
                transcript
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .renameMeetingAlert(renamingMeeting: $renamingMeeting, text: $renameText, context: context)
        // Slot assignment is call-order dependent by design (Theme's speaker-identity
        // vocabulary): this is the first point a meeting not opened before might need
        // one resolved. Re-keyed per meeting so switching in the sidebar re-runs it,
        // and a no-op for one that already has every current speaker slotted.
        .task(id: meeting.persistentModelID) {
            // See ``isTranscriptExpanded``: this view is reused across a sidebar
            // selection change, so the state has to be put back to collapsed here
            // rather than trusting the property initializer to have covered it.
            isTranscriptExpanded = ScreenshotMode.expandsTranscript
            isEditingRoughNotes = false
            // Same reuse story: a repair's result line belongs to the meeting it ran
            // on, so switching meetings has to clear it rather than carry it over.
            repairSummary = nil
            repairProbes = []
            repairAdvice = []
            meeting.resolveSpeakerSlots(ownerNames: SpeakerLabeling.ownerNames(context: context))
            try? context.save()
            // Same reuse story as the state resets above: the previous
            // meeting's player has to go before this meeting's audio loads,
            // or a stale instance keeps a time observer alive against an
            // asset nothing renders anymore. Loading last keeps every
            // synchronous reset ahead of the one await in this task.
            playerModel.teardown()
            playerModel = MeetingAudioPlayerModel()
            let urls = MeetingAudioPlayback.channelFileURLs(for: meeting)
            if !urls.isEmpty {
                await playerModel.load(urls: urls)
            }
            // Last, because it reads the CAFs to decide whether a channel looks
            // repairable, and everything above is what the meeting needs to render.
            await refreshRepairState()
        }
        .onDisappear { playerModel.teardown() }
        // Never both at once (see #14 and the mic-hears-your-speakers issue,
        // #5): a recording starting must actively pause audio that was already
        // playing, not just leave the controls disabled from here on.
        .onChange(of: session.state) { _, newState in
            if newState != .idle { playerModel.pause() }
        }
        .alert("Couldn't identify speakers", isPresented: $relabelError.presented()) {
            Button("OK") { relabelError = nil }
        } message: {
            Text(relabelError ?? "")
        }
        .alert("Couldn't transcribe that channel again", isPresented: $repairError.presented()) {
            Button("OK") { repairError = nil }
        } message: {
            Text(repairError ?? "")
        }
        .confirmationDialog(
            DeleteMeetingConfirmation.title(for: meeting.title),
            isPresented: $isDeleteConfirming,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DeleteMeetingConfirmation.message)
        }
        .alert("Couldn't delete meeting", isPresented: $deleteError.presented()) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .alert("Couldn't convert meeting", isPresented: $convertError.presented()) {
            Button("OK") { convertError = nil }
        } message: {
            Text(convertError ?? "")
        }
        .toolbar {
            ToolbarItem {
                // Refused while a pass is rewriting this meeting (issue #161).
                // What this shares is the notes and the transcript as they stand,
                // and mid-pipeline both are about to change: diarization is still
                // replacing channel labels with names, and enhancement hasn't
                // written the summary that the same export will carry a minute
                // later. A share taken here is a document the app itself
                // contradicts, with nothing in it saying it was partial.
                ShareLink(item: exportMarkdown()) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(session.isMidPipeline(meeting))
            }
            ToolbarItem {
                // Same write, and the same `canDelete` guard, as the library
                // list's context menu item — see `Meeting.toggleKind()` for what
                // conversion does and deliberately doesn't do (issue #107), and
                // `convertMeetingKind` for why both entry points share this call
                // rather than each going through their own general-purpose save.
                Button {
                    convertError = convertMeetingKind(meeting, context: context)
                } label: {
                    Label(
                        meeting.kind == .directive ? "Convert to Meeting" : "Convert to Directive",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(!session.canDelete(meeting))
            }
            ToolbarItem {
                // Reachable even for the meeting currently recording (selecting it
                // mid-call replaces the live view with this one) — `.disabled`
                // rather than omitted, matching the library list's context menu, so
                // the control doesn't appear to vanish depending on state.
                // `canDelete` also covers this view's own "Re-identify speakers"
                // pass: it mutates `meeting.segments` across an `await`, and a
                // delete racing that would resume the pass against an already-
                // deleted model. See `CaptureSession.canDelete(_:)`.
                Button(role: .destructive) {
                    isDeleteConfirming = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!session.canDelete(meeting))
            }
        }
    }

    /// The one place the title renders (#104c) — no `.navigationTitle` alongside
    /// it, unlike an earlier version of this view, which showed the same string
    /// twice: once in the window's title bar and again here. `RecordingView`
    /// sets no `navigationTitle` either, for the live equivalent of this same
    /// heading, so this brings the finished-meeting view in line with it rather
    /// than inventing a second convention.
    ///
    /// The pencil (#104d) is the visible half of a flow that already existed —
    /// `MeetingListView`'s "Rename" context menu — surfaced here because a
    /// context-menu-only affordance reads as "there is no edit button" rather
    /// than "right-click to rename." Both drive the identical alert; see
    /// `renameMeetingAlert`.
    ///
    /// The processing line (issue #173) sits here, once, rather than beside each
    /// control it explains: it is the first thing on screen when the meeting opens
    /// and it is adjacent to the toolbar, and repeating it per control would say
    /// the same sentence half a dozen times in one window.
    ///
    /// It explains one fact — a pass is rewriting this meeting — but the gates it
    /// speaks for are deliberately three, because the affordances aren't all
    /// unavailable for the same span (issue #161):
    ///
    /// - ``CaptureSession/isMidPipeline(_:)`` — Export, the rename pencil, the
    ///   rough-notes editor. Exactly while a pass rewrites the meeting, which is
    ///   the same condition the line renders, so what the app forbids and what it
    ///   says can't drift apart. Not the broader ``isProcessing(_:)``: that counts
    ///   the session's meeting through all of `.recording` and `.holding`, the two
    ///   windows the notes editor exists for.
    /// - ``CaptureSession/isProcessing(_:)`` — Re-identify and Run callback, which
    ///   also have nothing to act on until a first pass has finished.
    /// - ``CaptureSession/canDelete(_:)`` — Convert and Delete, whose refusal is
    ///   about the row going out from under the session, not about a pass.
    ///
    /// The line's wording therefore describes the pass, not the whole of what each
    /// control waits for; a control disabled during recording is disabled for a
    /// reason the line doesn't claim to give.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.x1) {
                Text(meeting.title)
                    .font(.title2.weight(.semibold))
                Button {
                    renameText = meeting.title
                    renamingMeeting = meeting
                } label: {
                    // `.iconOnly` keeps the glyph-only look but leaves the label's
                    // text as what VoiceOver announces — a bare `Image` would
                    // otherwise read out the SF Symbol's name ("pencil") rather
                    // than what the button does.
                    Label("Rename meeting", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Colors.textSecondary)
                .help("Rename meeting")
                // `isProcessing`, which is wider than the export gate above, and
                // deliberately (issue #161): it also covers this session's own
                // meeting for the length of a recording and a hold. A rename
                // commits on the alert's Save, so the grace deadline can expire
                // between opening it and saving — processing would then export
                // the old title and the Save would rename an already-processed
                // meeting afterward. `RecordingView`'s inline title field is the
                // rename path while a meeting belongs to this session, because
                // that one is observed and restarts the grace window as it's
                // typed.
                .disabled(session.isProcessing(meeting))
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            if let phase = session.processingPhase(for: meeting) {
                ProcessingIndicator(label: phase.label, prominence: .section)
                    .padding(.top, Theme.Space.x1)
            }
        }
    }

    private var subtitle: String {
        var parts = [meeting.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let endedAt = meeting.endedAt {
            let elapsed = Int(endedAt.timeIntervalSince(meeting.startedAt).rounded())
            parts.append(
                Duration.seconds(elapsed).formatted(
                    .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
                )
            )
        } else {
            // No end date means the app quit mid-recording; say so rather than
            // showing a duration of zero.
            parts.append("didn’t finish recording")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var notes: some View {
        if let notes = meeting.enhancedNotes, !notes.isEmpty {
            MarkdownNotesView(markdown: notes)
        } else {
            // Summarization can fail, or never have run. The transcript below is
            // still the record, so point at it.
            Label(
                "No enhanced notes for this meeting — the transcript below is intact.",
                systemImage: "sparkles"
            )
            .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    /// Notes stayed frozen once a meeting ended (#109) — this is the same
    /// `roughNotes` field ``RecordingView`` writes live, just editable again after
    /// the fact. A follow-up thought jotted the minute a call ends is otherwise
    /// lost the moment the app is closed, which is exactly when it's most likely to
    /// occur to someone.
    ///
    /// Editing here does **not** re-run summarization — the caption says so
    /// outright rather than leaving it to be discovered. Re-enhancing on every
    /// keystroke (or even on every edit) would mean re-running the on-device model
    /// and re-deciding action-item ownership each time, which is a real feature on
    /// its own, not a side effect of making a text field writable; that's future
    /// work (see the PR this shipped in) if it's wanted at all.
    ///
    /// This view is reachable for the meeting actively recording too — selecting it
    /// mid-call replaces `RecordingView` with this one (see the toolbar's delete
    /// button below). `CaptureSession.stop()` later does `meeting.roughNotes =
    /// roughNotes`, unconditionally copying its own transient scratchpad into the
    /// model — a straight `meeting.roughNotes` binding here would let an edit made
    /// from this view during that window get silently overwritten by that copy the
    /// moment recording stops. Binding to `session.roughNotes` instead, exactly the
    /// way `RecordingView` already does, means both views are windows onto the same
    /// value rather than two separate ones racing to land last.
    ///
    /// Markdown rendering (#108) is an Edit toggle, not live-as-you-type. While
    /// recording, this is unconditionally the plain `TextEditor` below — typing
    /// latency during a meeting is what `RecordingView`'s scratchpad protects, and
    /// re-parsing Markdown on every keystroke would be at odds with that for a
    /// field this view doesn't even own (`session.roughNotes` does; see above).
    /// Once the meeting has ended, the default view is ``MarkdownNotesView`` —
    /// the same block renderer the enhanced notes above already use, so headings
    /// and lists render here too, not just the bold/italic `Text(markdown:)` gets
    /// for free — and "Edit" swaps to the same plain editor a live meeting gets,
    /// with "Done" swapping back.
    private var roughNotes: some View {
        @Bindable var session = session
        let isLiveMeeting = session.meeting == meeting
        // Held open, but read-only, while a pass is rewriting this meeting (issue
        // #161). `process` feeds these notes to the summarizer and then ships them
        // again in the callback's export, with two long awaits in between, so a
        // keystroke landing in that window ends up in the notes, absent from the
        // summary that claims to be of them, and on either side of what the agent
        // was handed depending on where it fell. Disabled rather than swapped for
        // the rendered view: the text stays exactly where it was, and the phase
        // under the title says what it's waiting on.
        let isMidPipeline = session.isMidPipeline(meeting)

        // No explicit `context.save()` on the stored-model branch, which would be a
        // synchronous SwiftData write on every character typed. This environment's
        // `ModelContext` autosaves by default (unlike `MeetingQueryService`'s
        // read-only one), so the plain write is picked up the same way any other
        // field-level edit in this view is.
        let storedRoughNotes = Binding(get: { meeting.roughNotes }, set: { meeting.roughNotes = $0 })
        let isEditing = isLiveMeeting || isEditingRoughNotes

        return VStack(alignment: .leading, spacing: Theme.Space.x1) {
            HStack {
                Text("Rough notes")
                    .font(.headline)
                Spacer()
                // Nothing to toggle while recording — see the doc comment above.
                if !isLiveMeeting {
                    Button(isEditingRoughNotes ? "Done" : "Edit") {
                        isEditingRoughNotes.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(isMidPipeline)
                }
            }
            if isEditing {
                TextEditor(text: isLiveMeeting ? $session.roughNotes : storedRoughNotes)
                    .disabled(isMidPipeline)
                    .font(.body)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.x1)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .accessibilityLabel("Rough notes")
            } else if !MarkdownBlock.blocks(in: meeting.roughNotes, preservingLineBreaksInParagraphs: true).isEmpty {
                // Checking `blocks(in:)` itself, not `meeting.roughNotes.isEmpty` —
                // whitespace-only notes (a stray space, a blank line left over from
                // an edit) are non-empty as a string but parse to zero blocks, and
                // asking the parser directly is what keeps this in agreement with
                // what it's about to render instead of guessing at "blank" with a
                // second, separately-maintained trim check.
                //
                // `preservesLineBreaksInParagraphs: true` — see
                // ``MarkdownBlock/blocks(in:preservingLineBreaksInParagraphs:)``.
                // A rough note is typed as one line per thought with no blank line
                // between them (see the demo seed data), unlike the summarizer's
                // prose above, which wraps a sentence across lines on purpose.
                MarkdownNotesView(markdown: meeting.roughNotes, preservesLineBreaksInParagraphs: true)
            } else {
                Text("No rough notes for this meeting yet.")
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            // Only true once the meeting has actually ended and been enhanced —
            // while it's still recording, nothing above has run yet to be stale.
            if !isLiveMeeting {
                // Doesn't assume a summary exists — enhancement can fail, or a
                // recording can be abandoned before it ever finished — so this only
                // states what's unconditionally true rather than claiming there's
                // always something above for an edit to disagree with.
                Text(
                    "Notes added here stay with the meeting. If a summary already ran above, it won't include edits made after the meeting ended."
                )
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    /// Which segment indices (into ``sortedSegments``) get a leading mm:ss stamp —
    /// see ``TranscriptTimestamp/markedIndices(startTimes:)`` for why "one per
    /// elapsed minute" is the density that stays quiet at any turn-taking pace.
    private var timestampedIndices: Set<Int> {
        TranscriptTimestamp.markedIndices(startTimes: sortedSegments.map(\.startTime))
    }

    private var transcript: some View {
        DisclosureGroup(isExpanded: $isTranscriptExpanded) {
            if sortedSegments.isEmpty {
                Text("No transcript for this meeting.")
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.top, 6)
            } else {
                let marked = timestampedIndices
                VStack(alignment: .leading, spacing: 6) {
                    // Absolute, local time zone — the transcript's one wall-clock
                    // anchor; every stamp below it is relative to this instant, not
                    // to each other, so someone jumping in mid-meeting has one
                    // fixed point to convert from.
                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.Colors.textSecondary)

                    // Lazy: a long meeting runs to hundreds of lines, and each one
                    // carries a menu now.
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(sortedSegments.enumerated()), id: \.element.persistentModelID) {
                            index,
                            segment in
                            VStack(alignment: .leading, spacing: 2) {
                                if marked.contains(index) {
                                    // Orientation only (#130) — one per elapsed
                                    // minute, and never interactive. The seek
                                    // affordance (#123) is per row instead,
                                    // hover-revealed at the trailing edge, so
                                    // it can be exact without becoming the
                                    // column of numbers this stamp avoids.
                                    Text(TranscriptTimestamp.format(segment.startTime))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                }
                                HStack(alignment: .top, spacing: 8) {
                                    speakerMenu(for: segment)
                                    Text(segment.text)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        // VoiceOver's route to tap-to-seek: it
                                        // can't hover, and the button below is
                                        // invisible (and unfocusable) until
                                        // something does. Purged audio offers no
                                        // action, like the button; and because a
                                        // custom action can't be *disabled*, only
                                        // absent, the recording gate the button
                                        // expresses as `.disabled` has to remove
                                        // this action entirely — otherwise
                                        // VoiceOver could restart playback
                                        // mid-capture (never both at once, #14/#5).
                                        .accessibilityActions {
                                            if playerModel.isReady && session.state == .idle {
                                                Button(seekActionName(for: segment)) {
                                                    playerModel.playFrom(segment.startTime)
                                                }
                                            }
                                        }
                                    if playerModel.isReady {
                                        seekButton(for: segment)
                                    }
                                }
                            }
                            .onHover { hovering in
                                // Entering the next row can fire before exiting
                                // this one, so an exit only clears its own claim
                                // — never whichever row won since.
                                if hovering {
                                    hoveredSegmentID = segment.persistentModelID
                                } else if hoveredSegmentID == segment.persistentModelID {
                                    hoveredSegmentID = nil
                                }
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            Text("Transcript (\(sortedSegments.count) segments)")
                .font(.headline)
        }
    }

    private func seekActionName(for segment: TranscriptSegment) -> String {
        "Play from \(TranscriptTimestamp.format(segment.startTime))"
    }

    /// One transcript row's tap-to-seek control (#123): the segment's own mm:ss
    /// in the per-minute stamps' treatment, plus a play glyph so it reads as
    /// "go here", not another passive timestamp. Rendered at all only once the
    /// player loaded — audio that retention purged never shows it, matching how
    /// ``MeetingAudioPlayerView``'s caller shows nothing rather than a disabled
    /// control — and merely *disabled* while a recording runs, matching the
    /// player controls it drives. Hidden-by-opacity so revealing it never
    /// reflows the selectable text beside it, with hit testing *and*
    /// focusability gated to the same reveal. The hit-testing gate keeps an
    /// invisible click target past the end of a line from swallowing clicks
    /// meant to start a text selection there. The focusability gate exists
    /// because opacity doesn't take a button out of Full Keyboard Access's Tab
    /// order: without it, Tab lands on — and Space *activates* — a control
    /// with no visible presence (measured, not assumed). Reveal-on-focus
    /// isn't an option: no SwiftUI signal (`@FocusState` via `.focused`, or
    /// `\.isFocused` in the label or a `ButtonStyle`) fires when a bridged
    /// button takes key-loop focus on macOS 26, `.focusable(true)` adds a
    /// second, Space-inert tab stop beside the button's own — and even
    /// working, a tab stop per line is the keyboard shape of the number
    /// column #130 avoids. So this control is pointer-only, unconditionally
    /// out of the Tab order: keyboard users get the scrubber, VoiceOver keeps
    /// the per-line action above (its navigation isn't the Tab loop).
    private func seekButton(for segment: TranscriptSegment) -> some View {
        let isRevealed = hoveredSegmentID == segment.persistentModelID
        return Button {
            playerModel.playFrom(segment.startTime)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "play.fill")
                    .font(.system(size: 7))
                Text(TranscriptTimestamp.format(segment.startTime))
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(Theme.Colors.accent)
        }
        .buttonStyle(.borderless)
        .disabled(session.state != .idle)
        .focusable(false)
        .opacity(isRevealed ? 1 : 0)
        .allowsHitTesting(isRevealed)
        // Pointer-only by design: keyboard is out of the Tab loop above, and
        // VoiceOver already has the same labeled action on the line's text —
        // exposing this (often invisible) button too would read as a duplicate.
        .accessibilityHidden(true)
        .help(seekActionName(for: segment))
    }

    /// The speaker label, as a menu for fixing one line. Whole-speaker renames live in
    /// ``MeetingSpeakersSection`` — this is for the odd line the diarizer put on the
    /// wrong person.
    private func speakerMenu(for segment: TranscriptSegment) -> some View {
        Menu {
            ForEach(candidateLabels(for: segment), id: \.self) { label in
                Button(label) {
                    let prior = SegmentLabelState(segment)
                    segment.assignSpeaker(label)
                    save(restoring: segment, to: prior)
                }
            }
            if segment.isSpeakerLabelManual {
                // Exclusive to a line someone actually retyped: it reverts to the
                // capture channel, which would be the wrong action for a confirmed
                // line below — that label was never wrong, only unconfirmed.
                Divider()
                Button("Undo my change") {
                    let prior = SegmentLabelState(segment)
                    segment.assignSpeaker(nil)
                    save(restoring: segment, to: prior)
                }
            } else if segment.isSpeakerLabelConfirmed {
                // Non-destructive: the label stays, only the settled bit clears, so
                // the ring comes back instead of the line reverting to Me/Them.
                Divider()
                Button("Unconfirm") {
                    let prior = SegmentLabelState(segment)
                    segment.isSpeakerLabelConfirmed = false
                    save(restoring: segment, to: prior)
                }
            }
        } label: {
            // A minimum-width rail, not a fixed 72pt one — `SpeakerRailLabel`'s
            // provenance styling (bold, primary text for a settled label) already
            // carries what the hand icon used to say on its own.
            SpeakerRailLabel(speaker(for: segment))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Who this line could plausibly belong to: anyone enrolled, plus the other
    /// speakers on this line's own channel. Another channel's "Speaker 1" is an
    /// unrelated person, so it isn't offered.
    private func candidateLabels(for segment: TranscriptSegment) -> [String] {
        var seen = Set([segment.displayLabel])
        var labels: [String] = []
        for name in enrolled.map(\.name) where seen.insert(name).inserted {
            labels.append(name)
        }
        for summary in meeting.speakerSummaries {
            if let scoped = summary.scopedChannel, scoped != segment.channel { continue }
            if seen.insert(summary.label).inserted { labels.append(summary.label) }
        }
        return labels
    }

    /// The rollback ``MeetingSpeakersSection/enroll(_:as:)`` and
    /// ``MeetingSpeakersSection/confirm(_:)`` already get: a failed save must put a
    /// mutated segment back, or a later autosave persists an edit the person was just
    /// told had failed. All three of this menu's actions — rename, "Undo my change,"
    /// "Unconfirm" — go through this, since all three mutate one segment's label state
    /// and then save.
    private func save(restoring segment: TranscriptSegment, to prior: SegmentLabelState) {
        let ownerNames = SpeakerLabeling.ownerNames(context: context)
        meeting.resolveSpeakerSlots(ownerNames: ownerNames)
        meeting.reconcileActionItems(ownerNames: ownerNames)
        do {
            try context.save()
        } catch {
            prior.restore(to: segment)
            relabelError = error.localizedDescription
        }
    }

    /// "Run this meeting through an agent" (#137): every configured trigger is
    /// offered, not only the default — the automatic run already happened (or was
    /// declined), so this is the review-time surface where the *user's* pick is
    /// the whole point. One trigger gets a plain button; a list gets a menu of
    /// names. Busy-gated the same way re-identify is: `isProcessing` covers the
    /// live recording, a hold whose deadline could claim processing any moment,
    /// and launch recovery mid-pipeline — all states where the export this would
    /// build is about to be superseded.
    private var runTriggerSection: some View {
        let triggers = TranscriptCallbackSettings.triggers
        return VStack(alignment: .leading, spacing: Theme.Space.x1) {
            HStack(spacing: Theme.Space.x2) {
                // Buttons carry only the trigger's *id*; the command is
                // re-resolved when clicked (see `runTrigger(id:)`) — this list
                // is whatever was configured at render, and a Settings window
                // open beside this one can edit or delete a trigger in between.
                if triggers.count == 1, let only = triggers.first {
                    Button {
                        runTrigger(id: only.id)
                    } label: {
                        Label("Run callback", systemImage: "terminal")
                    }
                    .disabled(session.isProcessing(meeting))
                } else {
                    Menu {
                        ForEach(triggers) { trigger in
                            Button(trigger.displayName) { runTrigger(id: trigger.id) }
                                .disabled(trigger.trimmedCommand == nil)
                        }
                    } label: {
                        Label("Run callback", systemImage: "terminal")
                    }
                    .fixedSize()
                    .disabled(session.isProcessing(meeting))
                }
                Text("Hands this meeting's transcript to a trigger from Settings → Callback.")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            // The same shared status line Settings shows, because the run it
            // reports may well have been started right here.
            CallbackStatusLabel()
        }
    }

    /// "Transcribe this meeting's retained audio again" (#14) — the recovery path
    /// for a transcript that came out empty or one-sided, per channel rather than
    /// per meeting, because the case it exists for is one channel missing and the
    /// other fine.
    ///
    /// The attention line above the control is the whole reason this is findable:
    /// `TranscriptionCoverage` (#176) can tell that a channel captured real audio
    /// and produced no text, so the app says which half is missing and how long the
    /// audio has left, instead of leaving someone to notice on their own before
    /// retention takes the only copy.
    private var retranscribeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x1) {
            ForEach(repairAdvice, id: \.channel) { coverage in
                // Wraps rather than truncates, like the other long attention lines
                // on this page (see `MeetingSpeakersSection`) — the retention window
                // is the end of the sentence and the part with a deadline in it.
                StatusLabel(.attention, advisory(for: coverage))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.x2) {
                // One channel on disk gets a plain button, several get a menu — the
                // same shape `runTriggerSection` uses, for the same reason: naming
                // the one thing that can happen beats a menu of one.
                if repairProbes.count == 1, let only = repairProbes.first {
                    Button {
                        retranscribe(only.channel)
                    } label: {
                        Label(retranscribeActionName(only.channel), systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(isRepairBusy)
                } else {
                    Menu {
                        ForEach(repairProbes, id: \.channel) { probe in
                            Button(retranscribeActionName(probe.channel)) { retranscribe(probe.channel) }
                        }
                    } label: {
                        Label("Transcribe again", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .fixedSize()
                    .disabled(isRepairBusy)
                }
                Text(
                    "Reads the retained audio through transcription again, one channel at a time. Lines you renamed or confirmed are kept; the notes above aren't regenerated."
                )
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let repairSummary {
                Text(repairSummary)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    /// Disabled while *any* recording runs, not just while this meeting is being
    /// mutated — see `TranscriptRepair.audioFile(for:in:isBusy:)`: this pass starts
    /// a third transcription engine and reads a file as fast as the disk allows,
    /// which is not something to put next to a live meeting.
    private var isRepairBusy: Bool {
        ChannelRetranscription.isBusy(meeting, session: session)
    }

    /// Channels named the way the transcript names them, with the hardware said out
    /// loud once — "Me" alone doesn't tell you which recording is about to be read.
    private func channelName(_ channel: SpeakerChannel) -> String {
        channel == .me ? "Me (your microphone)" : "Them (system audio)"
    }

    private func retranscribeActionName(_ channel: SpeakerChannel) -> String {
        "Transcribe \(channelName(channel)) again"
    }

    private func advisory(for coverage: TranscriptionCoverage) -> String {
        let missing =
            coverage.channel == .me
            ? "This meeting's microphone recording has audio in it but produced no transcript, so your side of the conversation is missing."
            : "This meeting's system-audio recording has audio in it but produced no transcript, so the other side of the conversation is missing."
        return "\(missing) \(retentionWarning)"
    }

    /// How long there is to repair this meeting. Worth saying next to the prompt:
    /// the default retention is three days, so a transcript that came out wrong
    /// loses the only evidence it could be fixed from that quickly.
    private var retentionWarning: String {
        switch AudioRetention.current {
        case .forever:
            "The audio is kept until you change Settings → Privacy."
        case .none:
            "Audio isn't being kept, so this recording won't survive the next purge."
        case .day, .threeDays, .week, .month:
            "The audio is deleted \(AudioRetention.current.label) after a meeting ends, so that's how long there is to repair it."
        }
    }

    private func retranscribe(_ channel: SpeakerChannel) {
        Task { await runRepair(channel) }
    }

    /// Re-transcribes one channel. Everything about the pass itself — the engine,
    /// the merge rule, the diarization after — belongs to `ChannelRetranscription`;
    /// this is the click and the wording that follows it.
    private func runRepair(_ channel: SpeakerChannel) async {
        // The control is disabled on the same condition, but a click can be in
        // flight when the disable lands — this is the check that holds. (The run
        // re-checks it a third time before taking its mark, since that's the only
        // one both entry points share.)
        guard !isRepairBusy else { return }
        repairSummary = nil
        do {
            let outcome = try await ChannelRetranscription.run(
                channel: channel, meeting: meeting, session: session, context: context)
            repairSummary = repairSummaryText(outcome, channel: channel)
        } catch {
            repairError = error.localizedDescription
        }
        // Either way: a successful pass changes the segment counts the prompt is
        // derived from, and a failed one may have changed nothing at all — both
        // want the state re-read rather than guessed at.
        await refreshRepairState()
    }

    private func repairSummaryText(_ outcome: TranscriptRepair.Outcome, channel: SpeakerChannel) -> String {
        guard outcome.inserted > 0 else {
            return "No speech was found in the \(channelName(channel)) recording."
        }
        var parts = ["Transcribed \(lineCount(outcome.inserted)) from the \(channelName(channel)) recording"]
        if outcome.replaced > 0 { parts.append("replacing \(lineCount(outcome.replaced))") }
        if outcome.kept > 0 { parts.append("keeping \(lineCount(outcome.kept)) you’d settled") }
        if outcome.skipped > 0 { parts.append("skipping \(lineCount(outcome.skipped)) that overlapped those") }
        return parts.joined(separator: ", ") + "."
    }

    private func lineCount(_ count: Int) -> String {
        "\(count) line\(count == 1 ? "" : "s")"
    }

    /// Re-reads what can be repaired and what wants repairing.
    ///
    /// Nothing is offered until the recording has actually ended: mid-call the CAF
    /// is still being written, and a channel that hasn't finalized a line yet would
    /// otherwise be diagnosed as a failure — the one moment "audio but no
    /// transcript" is normal. `endedAt`, not `endedCleanly`, because a crash-
    /// abandoned recording is exactly the kind of half-transcript this repairs.
    private func refreshRepairState() async {
        guard meeting.endedAt != nil else {
            repairProbes = []
            repairAdvice = []
            return
        }
        let probes = TranscriptRepair.probes(in: meeting)
        repairProbes = probes
        // The measurement reads and decodes audio *synchronously*, so it must not
        // run here: `channelsWantingRepair` is `@concurrent`, which is what takes it
        // off the main actor — being `async` alone wouldn't, since a nonisolated
        // async function can run on its caller's executor. It also only measures a
        // channel with no segments at all, so an intact meeting reads nothing.
        repairAdvice = await TranscriptRepair.channelsWantingRepair(probes)
    }

    /// Same discipline as Settings' "Run now on last meeting": the export reads
    /// `stableID`, which backfills `uuid` on an old meeting, and that ID is about
    /// to be handed to an external consumer as CHEERIO_MEETING_ID — persist it
    /// first or don't run at all, reporting on the status line either way.
    private func runTrigger(id: UUID) {
        // The menu is disabled on the same condition, but a click can be in
        // flight when the disable lands — this is the check that holds.
        guard !session.isProcessing(meeting) else { return }
        // Resolved *now*, not at render: `observedTriggersData` refreshes the
        // menu when Settings edits triggers, but a re-render is an eventual
        // courtesy, not a guarantee at the instant of the click — an open menu
        // built from the previous configuration can still deliver its action
        // after an edit lands. The command that runs must be the one configured
        // at the moment of the click, so it's read here, from the id alone. A
        // trigger that's been deleted (or blanked) in that window refuses to
        // run, on the same status line a failed run would use, rather than
        // executing a command the user can no longer see — and deliberately
        // *without* the fire-time fallback to the default, which here would run
        // a different command than the one clicked.
        guard let command = TranscriptCallbackSettings.trigger(withID: id)?.trimmedCommand else {
            TranscriptCallbackStatus.shared.markFailedBeforeStarting(
                title: meeting.title,
                detail: "That trigger was removed or its command cleared in Settings, so nothing was run."
            )
            return
        }
        let ownerNames = SpeakerLabeling.ownerNames(context: context)
        let export = meeting.export(ownerNames: ownerNames)
        do {
            try context.save()
        } catch {
            TranscriptCallbackStatus.shared.markFailedBeforeStarting(
                title: export.title,
                detail: "Couldn't save this meeting's ID, so the command wasn't run: \(error.localizedDescription)"
            )
            return
        }
        TranscriptReadyRunner.fireManually(command: command, export: export)
    }

    /// Re-runs diarization. Worth offering because labels improve as more voices get
    /// enrolled, and the audio stays on disk until retention purges it.
    private func relabel() async {
        // The button above is disabled on the same condition, but a click can be
        // in flight when the disable lands — this is the check that actually
        // holds. The marks are reference-counted so an overlap wouldn't corrupt
        // *them* anymore; it's the two concurrent diarization passes this refuses.
        guard !session.isProcessing(meeting) else { return }
        // Before the first `await` below, so nothing can observe this meeting as
        // deletable between that call starting and this line running. Cleared in
        // the `defer`, which runs on the error path too — see `CaptureSession`.
        // The phase is named here because this pass has exactly one stage; the
        // full pipeline reports each of its own as it reaches them.
        session.beginProcessing(meeting, phase: .identifyingSpeakers)
        defer { session.endProcessing(meeting) }
        do {
            try await SpeakerLabeling.label(meeting: meeting, context: context)
            let ownerNames = SpeakerLabeling.ownerNames(context: context)
            meeting.resolveSpeakerSlots(ownerNames: ownerNames)
            // A fresh diarization pass rewrites non-manual labels wholesale — the
            // same trust-state invalidation as a hand correction, so the persisted
            // items must be re-checked the same way (see Meeting.reconcileActionItems).
            meeting.reconcileActionItems(ownerNames: ownerNames)
            try? context.save()
        } catch {
            relabelError = error.localizedDescription
        }
    }

    /// Commits the toolbar's "Delete" flow, after confirmation.
    private func delete() {
        let meetingID = meeting.persistentModelID
        do {
            // `context.container`, not `context` itself — see
            // `MeetingDeletion.delete(meetingID:container:)` for why this needs
            // its own context rather than the one this view shares with a
            // possibly in-flight recording.
            try MeetingDeletion.delete(meetingID: meetingID, container: context.container)
            session.meetingWasDeleted(meetingID)
            onDelete()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// The chip-and-name view model for one transcript line, reading provenance
    /// straight off the model rather than inventing it here — see
    /// ``SpeakerProvenance/init(isSettled:isDiarizerGeneratedLabel:hasName:)``.
    /// The slot itself is a lookup, not an assignment: ``Meeting/resolveSpeakerSlots(ownerNames:)``
    /// is what hands new slots out, at the points above where speakers actually resolve,
    /// so this stays a pure read safe to call from `body`.
    private func speaker(for segment: TranscriptSegment) -> Speaker {
        let isDiarizerGenerated = TranscriptSegment.isDiarizerGeneratedLabel(segment.speakerLabel)
        let provenance = SpeakerProvenance(
            isSettled: segment.isSpeakerLabelManual || segment.isSpeakerLabelConfirmed,
            isDiarizerGeneratedLabel: isDiarizerGenerated,
            hasName: segment.speakerLabel != nil && !isDiarizerGenerated
        )
        let slot = meeting.speakerSlotAssigner.assignments[segment.speakerSlotKey] ?? .unresolved
        return Speaker(id: segment.speakerSlotKey, name: segment.displayLabel, slot: slot, provenance: provenance)
    }

    private func exportMarkdown() -> String {
        var out = "# \(meeting.title)\n\(meeting.startedAt.formatted())\n\n"
        if let notes = meeting.enhancedNotes { out += notes + "\n\n" }
        out += "## Transcript\n\(meeting.transcriptText)\n"
        return out
    }
}

/// A snapshot of the three fields ``speakerMenu(for:)``'s actions can change on one
/// segment, taken before the mutation so a failed save has something to put back.
private struct SegmentLabelState {
    let label: String?
    let isManual: Bool
    let isConfirmed: Bool

    init(_ segment: TranscriptSegment) {
        label = segment.speakerLabel
        isManual = segment.isSpeakerLabelManual
        isConfirmed = segment.isSpeakerLabelConfirmed
    }

    func restore(to segment: TranscriptSegment) {
        segment.speakerLabel = label
        segment.isSpeakerLabelManual = isManual
        segment.isSpeakerLabelConfirmed = isConfirmed
    }
}
