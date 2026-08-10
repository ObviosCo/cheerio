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
    @State private var isRelabeling = false
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
    /// Which transcript row's seek affordance is visible. Hover-revealed rather
    /// than always-on: a stamp on every line is exactly the column of numbers
    /// the per-minute timestamps (#130) exist to avoid, and the row's text keeps
    /// `.textSelection(.enabled)`, so the tap target has to be its own control
    /// beside the text, not the line itself.
    @State private var hoveredSegmentID: PersistentIdentifier?

    private var sortedSegments: [TranscriptSegment] {
        meeting.segments.sorted { $0.startTime < $1.startTime }
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
                            Label(
                                isRelabeling ? "Identifying speakers…" : "Re-identify speakers",
                                systemImage: "person.wave.2"
                            )
                        }
                        .disabled(isRelabeling)
                        Text("Uses the voices enrolled in Settings → Participants.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                ShareLink(item: exportMarkdown()) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
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
                .foregroundStyle(.secondary)
                .help("Rename meeting")
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
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
            .foregroundStyle(.secondary)
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
                }
            }
            if isEditing {
                TextEditor(text: isLiveMeeting ? $session.roughNotes : storedRoughNotes)
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
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)

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
                                        .foregroundStyle(.tertiary)
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
            Text("Transcript (\(meeting.segments.count) segments)")
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
    /// reflows the selectable text beside it, with hit testing gated to the
    /// same hover: an invisible click target sitting past the end of a line
    /// would swallow clicks meant to start a text selection there.
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
        .opacity(isRevealed ? 1 : 0)
        .allowsHitTesting(isRevealed)
        .accessibilityLabel(seekActionName(for: segment))
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

    /// Re-runs diarization. Worth offering because labels improve as more voices get
    /// enrolled, and the audio stays on disk until retention purges it.
    private func relabel() async {
        isRelabeling = true
        // Before the first `await` below, so nothing can observe this meeting as
        // deletable between that call starting and this line running. Cleared in
        // the `defer`, which runs on the error path too — see `CaptureSession`.
        session.beginProcessing(meeting)
        defer {
            isRelabeling = false
            session.endProcessing(meeting)
        }
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
