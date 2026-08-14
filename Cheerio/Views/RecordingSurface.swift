import CheerioKit
import SwiftData
import SwiftUI

/// Everything the live-recording pane draws, as a function of plain values.
///
/// `RecordingView` is the shipped surface and owns the session; this owns the
/// pixels. The split exists because the accessibility audits and the screenshot
/// harness could reach every other screen in the app and not this one (#164):
/// `RecordingView` renders only while `CaptureSession.state` is
/// `.recording`/`.finishing`/`.holding`, that state is `private(set)` and only
/// moves when both capture channels have actually started, and `ScreenshotMode`'s
/// charter is explicit that nothing there can record. The seam had to go
/// somewhere; a test hook that made the *session* believe it was recording is the
/// one place it must not go — the menu bar, `UpdatePolicy`'s update gating and the
/// deletion guards all key off that same state, so a fake recording state would
/// sit one bug away from production. Presentation has no such reach: fixture
/// values in, pixels out, and `RecordingSurfacePreview` feeds them with the real
/// session still `.idle`.
///
/// The rule that keeps this honest: this view has no opinions of its own. Every
/// input is supplied by whoever owns the state, and every action is a closure —
/// so the audited view and the shipped view are the same code, not a copy of it.
struct RecordingSurface: View {
    /// Which live state to draw. Only `.recording`, `.finishing` and `.holding`
    /// ever reach here from `ContentView`; the value is read, never set, so
    /// passing one is not a claim that anything is capturing.
    let state: CaptureSession.State
    /// The meeting being recorded, if there is one. Nil drops the whole header —
    /// the title field, the kind badge, the roster menu, and the indicator — the
    /// same way it always has.
    let meeting: Meeting?
    /// `CaptureSession.ProcessingPhase.label` for this meeting, when a pass is
    /// running (issue #173). Present means the indicator takes the ring's place.
    let processingPhaseLabel: String?
    /// When capture began, for the elapsed timer and the transcript header's
    /// absolute start time.
    let startedAt: Date?
    let liveLines: [TranscriptionUpdate]
    let volatileLine: TranscriptionUpdate?
    /// When auto-processing takes over, in `.holding` (issue #136).
    let holdDeadline: Date?
    /// The encourage-not-block enrollment banner. Whether it has been shown before
    /// is `RecordingView`'s question, not this view's.
    let showsEnrollmentNudge: Bool

    @Binding var roughNotes: String
    @Binding var holdKind: MeetingKind
    @Binding var holdRunsCallback: Bool
    @Binding var holdTriggerID: UUID?
    @Binding var holdCallbackPrompt: String

    let onProcessNow: () -> Void
    let onStop: () -> Void
    /// The title field's `onSubmit` — a save, in the shipped view.
    let onTitleSubmit: () -> Void
    let onAddVoice: () -> Void
    let onDismissEnrollmentNudge: () -> Void

    /// Whether the live transcript should keep following new lines. Suspended the
    /// moment a scroll leaves the bottom edge, resumed only once one returns to
    /// it — see ``liveTranscriptScroll``.
    @State private var isPinnedToBottom = true
    /// The raw trigger-list blob, observed so the holding controls re-render
    /// when Settings edits triggers while a hold is on screen — a plain
    /// `TranscriptCallbackSettings.triggers` read in `body` is invisible to
    /// SwiftUI's invalidation, so the toggle and picker would keep showing a
    /// configuration that no longer exists. Never decoded here: the *value*
    /// still comes from `TranscriptCallbackSettings`, which owns normalization
    /// and the legacy-command migration; this property exists to be read (see
    /// ``holdingControls``) purely as the dependency that triggers the refresh.
    /// Settings writes the blob on every edit, including ones that only change
    /// the mirrored legacy key's value, so observing the blob alone suffices.
    @AppStorage(TranscriptCallbackSettings.triggersDefaultsKey) private var observedTriggersData: Data?

    var body: some View {
        VStack(spacing: 0) {
            if showsEnrollmentNudge {
                enrollmentNudgeBanner
                Divider()
            }

            // Renameable in place: the title is often wrong at the moment you notice
            // it — a calendar match that didn't apply, or a placeholder timestamp.
            if let meeting {
                @Bindable var meeting = meeting
                HStack(spacing: 8) {
                    // Routed through `rename(to:)` rather than a direct `$meeting.title`
                    // binding: a title typed here is exactly as manual as one typed from
                    // the library later, and both need to retire `isTitleAutomatic` so
                    // the auto-title pass at the end of the recording doesn't overwrite it.
                    TextField("Meeting name", text: Binding(get: { meeting.title }, set: { meeting.rename(to: $0) }))
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .onSubmit(onTitleSubmit)
                    // Same badge style as the library row (MeetingListView) — small
                    // affordance only, not a forked layout. It's the one visual cue
                    // that the scratchpad matters less for this recording.
                    if meeting.kind == .directive {
                        Text("Directive")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .capsule)
                    }
                    // Set the roster while you can see who's in the room — the automatic
                    // pass at the end of the recording uses it, so getting it right now
                    // saves a re-identify later.
                    ParticipantRosterMenu(meeting: meeting)
                    // Processing takes the ring's place rather than sitting beside
                    // it (issue #173): in `.finishing` the ring was still filled
                    // and the timer still counting, so a meeting whose grace period
                    // had just expired — or whose "Process Now" had just been
                    // clicked — read as *recording* while it was really being
                    // diarized and written up. One claim about what the machine is
                    // doing, and it has to be the true one.
                    if let processingPhaseLabel {
                        ProcessingIndicator(label: processingPhaseLabel, prominence: .section)
                    } else if state != .holding, let startedAt {
                        // Still nothing in `.holding`: the ring means "capturing
                        // right now", and the holding state's whole premise is that
                        // capture is over. The holding bar below carries that state.
                        //
                        // The ring and the word travel with the timer here, not just
                        // the digits — a bare timer is exactly the drift
                        // `RecordingIndicator` exists to stop between this header,
                        // the sidebar, and the menu bar.
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            RecordingIndicator(
                                isRecording: true,
                                elapsed: .seconds(Int(context.date.timeIntervalSince(startedAt).rounded()))
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }

            if state == .holding {
                holdingControls
                Divider()
            }

            recordingPanes
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if state == .holding {
                    Button(action: onProcessNow) {
                        Label("Process Now", systemImage: "sparkles")
                    }
                } else {
                    Button(action: onStop) {
                        Label(
                            state == .finishing ? "Finishing…" : "Stop",
                            systemImage: "stop.circle.fill"
                        )
                    }
                    .disabled(state == .finishing)
                }
            }
        }
    }

    /// The post-meeting holding state's controls (issue #136): the countdown to
    /// auto-processing, the meeting-kind switch, and the callback decision with
    /// its per-meeting prompt. Everything binds through the session's `hold*`
    /// accessors rather than the meeting directly, so each edit also restarts the
    /// grace window — the countdown measures idle time, and touching a control is
    /// not idle.
    private var holdingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .foregroundStyle(.tint)
                if let holdDeadline {
                    // `.timer` counts down on its own — no TimelineView needed —
                    // and the deadline moving on each edit is picked up because
                    // `holdDeadline` is observed state. "Processing", not "notes
                    // and callback": whether the callback is part of processing
                    // is exactly what the toggle to the right decides, and this
                    // line has to stay true in every position of it.
                    Text(
                        "Recording finished. Processing starts in \(Text(holdDeadline, style: .timer).fontWeight(.semibold)) — editing anything here keeps it waiting."
                    )
                    .font(.callout)
                }
                Spacer()
                Button("Process Now", action: onProcessNow)
                    .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 12) {
                // Cheap to change *now*, before notes exist to go stale — see
                // `CaptureSession.holdKind`. After processing it's the detail
                // view's convert action, with its documented regeneration caveat.
                Picker("Kind", selection: $holdKind) {
                    Text("Meeting").tag(MeetingKind.meeting)
                    Text("Directive").tag(MeetingKind.directive)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()

                // Reading the observed blob is what makes a Settings edit
                // mid-hold re-evaluate everything below — see
                // ``observedTriggersData``.
                let _ = observedTriggersData
                // Only offered when a trigger exists that could run — a toggle
                // that controls nothing would read as broken, and Settings ›
                // Callback is where triggers get configured in the first place.
                // `hasRunnableTrigger`, not `command != nil`: a blank default
                // with a usable second trigger still leaves something to choose.
                if TranscriptCallbackSettings.hasRunnableTrigger {
                    Toggle("Run callback", isOn: $holdRunsCallback)
                        .toggleStyle(.checkbox)
                    // The per-meeting trigger choice (#137). Hidden with one
                    // trigger configured, when there's nothing to choose — the
                    // single-command experience stays exactly what it was.
                    let triggers = TranscriptCallbackSettings.triggers
                    if triggers.count > 1 {
                        Picker("Trigger", selection: $holdTriggerID) {
                            ForEach(triggers) { trigger in
                                // Blank-command triggers stay visible but can't
                                // be chosen, matching the manual-run menus:
                                // picking one would leave "Run callback" checked
                                // while the fire decision deterministically
                                // no-ops on the blank command.
                                Text(trigger.displayName)
                                    .tag(trigger.id as UUID?)
                                    .selectionDisabled(trigger.trimmedCommand == nil)
                            }
                        }
                        .fixedSize()
                        .labelsHidden()
                        .accessibilityLabel("Callback trigger")
                        .disabled(!holdRunsCallback)
                    }
                    TextField(
                        "Additional prompt for the callback (CHEERIO_ADDITIONAL_PROMPT)",
                        text: $holdCallbackPrompt
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(!holdRunsCallback)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.tint.opacity(0.08))
    }

    private var enrollmentNudgeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.wave.2")
                .foregroundStyle(.tint)
            Text("Add your voice and, once this meeting ends, your lines will come back with your name instead of a generic speaker label.")
                .font(.callout)
            Spacer()
            Button("Add my voice", action: onAddVoice)
                .buttonStyle(.borderless)
            Button(action: onDismissEnrollmentNudge) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.15))
    }

    /// The bottom-anchor id every scroll-to-latest call targets, whether or not a
    /// volatile line currently exists — "volatile" alone would leave nothing to
    /// scroll to the instant a segment finalizes and clears it (``CaptureSession/handle(_:context:)``
    /// sets ``CaptureSession/volatileLine`` to nil in the same update that appends
    /// the final line), which is exactly when a scroll is most needed.
    private static let transcriptBottomAnchorID = "transcript-bottom"

    /// How close to the bottom edge still counts as "there" — a user who scrolled up
    /// half a line's height while a new one lands shouldn't have that read as
    /// intentionally leaving the bottom.
    private static let bottomFollowTolerance: CGFloat = 24

    @ViewBuilder private var recordingPanes: some View {
        // Notes on top and larger: typing is the job during a meeting, and the
        // transcript is reference material you glance at.
        VSplitView {
            TextEditor(text: $roughNotes)
                .font(.body)
                .padding(8)
                .frame(minHeight: 260, idealHeight: 460)
                .overlay(alignment: .topLeading) {
                    if roughNotes.isEmpty {
                        Text("Rough notes — jot anything; AI merges it with the transcript later.")
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                    // "Live" is a claim about capture, and in `.holding` capture is
                    // over — the banner above says "Recording finished", and this
                    // header contradicting it would leave doubt about whether the
                    // mic is still hot.
                    Text(state == .holding ? "Transcript" : "Live transcript")
                    if let startedAt {
                        // Absolute and local, per #130 — the per-line stamps below
                        // are all relative to this one instant.
                        Text("· started \(startedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.monospacedDigit())
                    }
                    Spacer()
                    Text("\(liveLines.count) lines")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                liveTranscriptScroll
            }
            .frame(minHeight: 120, idealHeight: 180)
        }
    }

    private var liveTranscriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let marked = TranscriptTimestamp.markedIndices(startTimes: liveLines.map(\.startTime))
                    ForEach(Array(liveLines.enumerated()), id: \.offset) { index, line in
                        transcriptLine(line, showsTimestamp: marked.contains(index))
                    }
                    if let volatileLine {
                        transcriptLine(volatileLine, showsTimestamp: false)
                            .opacity(0.5)
                    }
                    // Zero-height and always last, so there's one stable id to
                    // scroll to regardless of whether a volatile line exists right
                    // now — see ``transcriptBottomAnchorID``.
                    Color.clear.frame(height: 0).id(Self.transcriptBottomAnchorID)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            // `RecordingView` is recreated, not just re-shown, every time
            // `CheerioApp`'s detail branch swaps back to it from a selected
            // meeting (`if/else` between two different view types drops the old
            // one's state) — with no scroll history to restore, a fresh scroll
            // view otherwise opens at its content's top, on the oldest lines,
            // which is the opposite of "pinned as promised" for a meeting already
            // well underway. Anchoring the default here means a freshly-created
            // scroll view's very first layout already sits at the bottom, with
            // no `onChange` needing to have fired first.
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - Self.bottomFollowTolerance
            } action: { _, isAtBottom in
                isPinnedToBottom = isAtBottom
            }
            .onChange(of: liveLines.count) {
                guard isPinnedToBottom else { return }
                proxy.scrollTo(Self.transcriptBottomAnchorID, anchor: .bottom)
            }
            .onChange(of: volatileLine?.text) {
                guard isPinnedToBottom else { return }
                proxy.scrollTo(Self.transcriptBottomAnchorID, anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom {
                    jumpToLatestButton(proxy: proxy)
                }
            }
        }
    }

    /// Quiet on purpose — a filled circle no louder than the recording indicator
    /// elsewhere in this view, appearing only while following is suspended and
    /// gone the instant it isn't.
    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            isPinnedToBottom = true
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.transcriptBottomAnchorID, anchor: .bottom)
            }
        } label: {
            Label("Jump to latest", systemImage: "arrow.down.circle.fill")
                .labelStyle(.iconOnly)
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.Colors.textSecondary)
        .padding(6)
        .background(.regularMaterial, in: Circle())
        .padding(10)
        .transition(.opacity)
    }

    private func transcriptLine(_ line: TranscriptionUpdate, showsTimestamp: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsTimestamp {
                Text(TranscriptTimestamp.format(line.startTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            HStack(alignment: .top, spacing: 8) {
                // Both channels stay plain secondary text: speaker colour fills the
                // chip and the speakers-panel timeline, never transcript text (the
                // token map's rule) — and pre-diarization "Me" is channelDefault
                // provenance anyway, which carries no identity colour even on a chip.
                Text(line.channel == .me ? "Me" : "Them")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: 44, alignment: .trailing)
                Text(line.text)
                    .textSelection(.enabled)
            }
        }
    }
}
