import CheerioKit
import SwiftData
import SwiftUI

/// Live view during a meeting: transcript on the left, rough-notes
/// scratchpad on the right (the Granola pattern).
struct RecordingView: View {
    @Environment(CaptureSession.self) private var session
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<EnrolledSpeaker> { $0.isMe }) private var enrolledMe: [EnrolledSpeaker]

    /// Encourage-not-block, per the onboarding walkthrough: shown at most once ever
    /// (``OnboardingState/hasShownEnrollmentNudge``), and never stands between
    /// pressing "record" and the recording actually starting.
    @State private var showEnrollmentNudge = false
    @State private var showEnrollmentSheet = false
    /// Whether the live transcript should keep following new lines. Suspended the
    /// moment a scroll leaves the bottom edge, resumed only once one returns to
    /// it — see ``liveTranscriptScroll``.
    @State private var isPinnedToBottom = true

    var body: some View {
        @Bindable var session = session

        VStack(spacing: 0) {
            if showEnrollmentNudge {
                enrollmentNudgeBanner
                Divider()
            }

            // Renameable in place: the title is often wrong at the moment you notice
            // it — a calendar match that didn't apply, or a placeholder timestamp.
            if let meeting = session.meeting {
                @Bindable var meeting = meeting
                HStack(spacing: 8) {
                    // Routed through `rename(to:)` rather than a direct `$meeting.title`
                    // binding: a title typed here is exactly as manual as one typed from
                    // the library later, and both need to retire `isTitleAutomatic` so
                    // the auto-title pass at the end of the recording doesn't overwrite it.
                    TextField("Meeting name", text: Binding(get: { meeting.title }, set: { meeting.rename(to: $0) }))
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .onSubmit { try? context.save() }
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
                    if let startedAt = session.startedAt {
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

            recordingPanes
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.stop(context: context) }
                } label: {
                    Label(
                        session.state == .finishing ? "Finishing…" : "Stop",
                        systemImage: "stop.circle.fill"
                    )
                }
                .disabled(session.state == .finishing)
            }
        }
        .onAppear {
            // Only ever the first recording after a skipped enrollment — this view
            // reappears on every recording, but the persisted flag keeps it quiet
            // after the first showing.
            guard enrolledMe.isEmpty, !OnboardingState.hasShownEnrollmentNudge else { return }
            OnboardingState.hasShownEnrollmentNudge = true
            showEnrollmentNudge = true
        }
        .sheet(isPresented: $showEnrollmentSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add your voice")
                    .font(.headline)
                VoiceEnrollmentRecorder(markAsMe: true) { _ in
                    showEnrollmentSheet = false
                    // A successful enrollment resolves the reason the banner is up in
                    // the first place — leave it showing and it reads as a bug: "I just
                    // did what it asked, why is it still there?"
                    showEnrollmentNudge = false
                }
                Button("Done") { showEnrollmentSheet = false }
                    .buttonStyle(.bordered)
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    private var enrollmentNudgeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.wave.2")
                .foregroundStyle(.tint)
            Text("Add your voice and, once this meeting ends, your lines will come back with your name instead of a generic speaker label.")
                .font(.callout)
            Spacer()
            Button("Add my voice") { showEnrollmentSheet = true }
                .buttonStyle(.borderless)
            Button {
                showEnrollmentNudge = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
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
        @Bindable var session = session

        // Notes on top and larger: typing is the job during a meeting, and the
        // transcript is reference material you glance at.
        VSplitView {
            TextEditor(text: $session.roughNotes)
                .font(.body)
                .padding(8)
                .frame(minHeight: 260, idealHeight: 460)
                .overlay(alignment: .topLeading) {
                    if session.roughNotes.isEmpty {
                        Text("Rough notes — jot anything; AI merges it with the transcript later.")
                            .foregroundStyle(.tertiary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                    Text("Live transcript")
                    if let startedAt = session.startedAt {
                        // Absolute and local, per #130 — the per-line stamps below
                        // are all relative to this one instant.
                        Text("· started \(startedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.monospacedDigit())
                    }
                    Spacer()
                    Text("\(session.liveLines.count) lines")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
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
                    let marked = TranscriptTimestamp.markedIndices(startTimes: session.liveLines.map(\.startTime))
                    ForEach(Array(session.liveLines.enumerated()), id: \.offset) { index, line in
                        transcriptLine(line, showsTimestamp: marked.contains(index))
                    }
                    if let volatile = session.volatileLine {
                        transcriptLine(volatile, showsTimestamp: false)
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
            .onChange(of: session.liveLines.count) {
                guard isPinnedToBottom else { return }
                proxy.scrollTo(Self.transcriptBottomAnchorID, anchor: .bottom)
            }
            .onChange(of: session.volatileLine?.text) {
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
        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 8) {
                Text(line.channel == .me ? "Me" : "Them")
                    .font(.caption.bold())
                    .foregroundStyle(line.channel == .me ? .blue : .secondary)
                    .frame(width: 44, alignment: .trailing)
                Text(line.text)
                    .textSelection(.enabled)
            }
        }
    }
}
