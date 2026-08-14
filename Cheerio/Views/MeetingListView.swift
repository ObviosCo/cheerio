import CheerioKit
import SwiftData
import SwiftUI

struct MeetingListView: View {
    /// Bound to the split view's detail column, which is what actually has room to
    /// show a meeting.
    @Binding var selection: Meeting?

    @Environment(CaptureSession.self) private var session
    @Environment(\.modelContext) private var context
    @Query(sort: \Meeting.startedAt, order: .reverse) private var meetings: [Meeting]

    @State private var searchText = ""
    /// Drives `meetingSections`' "now" instead of sampling `Date.now` directly in
    /// the computed property. A computed property only re-evaluates when SwiftUI
    /// re-renders the view, which happens on state changes — not on the wall
    /// clock — so a library window left open past midnight with nothing else
    /// changing would keep showing yesterday's meetings under "Today" forever.
    /// `midnightRollover()` below is what actually advances this.
    @State private var now: Date = .now
    /// Keyed into `midnightRollover()`'s `.task(id:)` below, so a time-zone change
    /// restarts that loop instead of waiting out a deadline computed under the zone
    /// it just left. Updated by the `NSSystemTimeZoneDidChange` observer.
    @State private var timeZoneID = TimeZone.current.identifier
    /// The calendar event happening right now, offered as a title but never assumed.
    @State private var currentEvent: CalendarMeeting?
    /// A menu toggle rather than a section split: there aren't enough directives yet
    /// to earn their own part of the list, but hiding meetings while looking for one
    /// is already useful today.
    @State private var directivesOnly = false
    /// The meeting the "Rename" context-menu item was chosen for. Driving an alert
    /// off this (rather than an inline field in the row) keeps the row layout the
    /// same whether or not something's being renamed — the row's width is already
    /// tight with the directive badge and timestamp.
    @State private var renamingMeeting: Meeting?
    @State private var renameText = ""
    /// The meeting a "Delete" context-menu choice is confirming. Same off-optional
    /// pattern as ``renamingMeeting``, and for the same reason: nothing about the
    /// row layout should change while a delete is pending confirmation.
    @State private var deletingMeeting: Meeting?
    @State private var deleteError: String?
    /// Set from `convertMeetingKind`'s return value — the "Convert to…"
    /// context-menu item's own error, kept separate from ``deleteError`` so a
    /// failed kind flip doesn't borrow Delete's wording.
    @State private var convertError: String?

    /// Matches title, rough notes, enhanced notes, and transcript text. The library
    /// is one person's meetings, so filtering in memory is cheaper than rebuilding
    /// the query on every keystroke.
    private var visibleMeetings: [Meeting] {
        let base = directivesOnly ? meetings.filter { $0.kind == .directive } : meetings
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { $0.matches(query) }
    }

    /// `visibleMeetings`, bucketed into Today/Yesterday/weekday/absolute-date
    /// sections. Grouping runs after filtering, not before, so search (and any filter
    /// layered on top of it) always sees — and can empty out — a section before this
    /// does.
    ///
    /// `strategy` isn't exposed anywhere yet; date is the only one that exists. It's
    /// still a parameter on `MeetingListGrouping.sections` rather than something
    /// hard-coded into date logic here, so a second axis (grouping by project, #1)
    /// only has to add a case, not a rewrite.
    private var meetingSections: [MeetingListSection] {
        MeetingListGrouping.sections(for: visibleMeetings, now: now)
    }

    var body: some View {
        // Selection rather than a NavigationStack: a stack nested in the sidebar
        // pushed the meeting into the sidebar's own 280pt column and left the detail
        // column sitting on "No meeting selected".
        List(selection: $selection) {
            Section { recordingControls }

            if visibleMeetings.isEmpty, !searchText.isEmpty {
                Section("Meetings") {
                    Text("No meetings match “\(searchText)”.")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            } else if visibleMeetings.isEmpty, directivesOnly {
                Section("Meetings") {
                    Text("No directives yet.")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            } else {
                // One `Section` per date bucket instead of a single flat "Meetings"
                // section — empty buckets never appear because grouping only ever
                // produces a section for a day that has something in it. This runs on
                // `visibleMeetings`, which already reflects both the search text and
                // the directives-only toggle above, so the toggle and search need no
                // grouping-specific handling here — they're just a smaller input.
                ForEach(meetingSections) { section in
                    Section(section.title) {
                        ForEach(section.meetings) { meeting in
                            row(for: meeting)
                        }
                    }
                }
            }
        }
        .navigationTitle("Cheerio")
        .searchable(text: $searchText, prompt: "Search meetings")
        .toolbar {
            // A toggle, not a segmented control or a separate section: there are only
            // a handful of directives so far, and a menu item is the smallest way to
            // offer the filter without giving it its own piece of the layout.
            ToolbarItem(placement: .automatic) {
                Menu {
                    Toggle("Directives only", isOn: $directivesOnly)
                } label: {
                    Label(
                        "Filter",
                        systemImage: directivesOnly
                            ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                }
            }
        }
        .task {
            // No-op unless the screenshot harness passed its launch arguments; see
            // `ScreenshotMode`. Here rather than in `ContentView` because this is
            // where the sidebar's order is already resolved.
            if let index = ScreenshotMode.selectedMeetingIndex, meetings.indices.contains(index) {
                selection = meetings[index]
            }
        }
        .task {
            // Keep the calendar offer fresh as events start and end.
            while !Task.isCancelled {
                currentEvent = await CalendarService.shared.currentMeeting()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task(id: timeZoneID) {
            await midnightRollover()
        }
        // The other half of `midnightRollover()`'s time-zone handling: a zone
        // change mid-sleep changes `timeZoneID`, which cancels the `.task(id:)`
        // above and restarts it immediately under the new zone, rather than
        // waiting out a deadline the old zone already computed.
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            timeZoneID = TimeZone.current.identifier
        }
        .renameMeetingAlert(renamingMeeting: $renamingMeeting, text: $renameText, context: context)
        .confirmationDialog(
            DeleteMeetingConfirmation.title(for: deletingMeeting?.title ?? ""),
            isPresented: $deletingMeeting.presented(),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) { deletingMeeting = nil }
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
        // Both alerts below read the session, not local state, so a recording started
        // from the menu bar can explain itself here.
        .alert("Couldn't start recording", isPresented: startFailed) {
            Button("OK") { session.startFailure = nil }
        } message: {
            Text(session.startFailure?.message ?? "")
        }
        .alert("Cheerio needs microphone access", isPresented: microphoneDenied) {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turn on Microphone for Cheerio, then start recording again.")
        }
    }

    /// One row in the grouped list. The date already lives in the section header, so
    /// the subtitle carries who was there instead — a meeting's title tells you what
    /// it was, participants tell you who, and the two together are what you actually
    /// scan a library for. The time of day answers neither, which is why it isn't a
    /// fallback here: a meeting with no roster shows no subtitle at all rather than
    /// something less interesting than the title above it.
    ///
    /// While something is processing the meeting, the phase takes that second line
    /// instead of the roster (issue #173) — this is the first place someone looks
    /// to find out whether the app is working, and it's the only line in the row
    /// that can carry the answer without making the row a third line taller and
    /// reflowing the whole list every time a pass starts or ends. The roster is
    /// static and a click away in the detail view; which stage a pipeline is in is
    /// true for a minute and then gone.
    @ViewBuilder private func row(for meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(meeting.title).chText(.meetingTitle)
                // Set via "Give Direction…" in the menu bar (see MenuBarView); also
                // what the toolbar's "Directives only" toggle filters `visibleMeetings`
                // on above.
                if meeting.kind == .directive {
                    Text("Directive")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: .capsule)
                }
            }
            if let phase = session.processingPhase(for: meeting) {
                ProcessingIndicator(label: phase.label, prominence: .row)
            } else if let participants = participantsSubtitle(for: meeting) {
                Text(participants)
                    .chText(.meetingSubtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // Without this the clickable area is only as wide as the title.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .tag(meeting)
        // The row's own selection fill, replacing the system's accent pill —
        // `chText` pins catalog colours, which the emphasized system selection
        // can't re-colour, so the pairing has to be owned on this side. See
        // `chListRowSelection` for the whole argument.
        .chListRowSelection(isSelected: selection == meeting)
        .contextMenu {
            // Disabled for this session's own meeting and for anything a pass has
            // mid-flight (issue #161). The rename alert commits on Save, and
            // nothing about it is holding activity: selecting an earlier meeting
            // unmounts `RecordingView` and the title observer that restarts the
            // grace window with it, so the deadline can expire while the alert is
            // open — processing would export the old title and the Save would then
            // rename the finished meeting behind it. The tracked rename path for a
            // held meeting is `RecordingView`'s own title field, which is one
            // "Back to add notes" away in the controls above.
            Button("Rename") {
                renameText = meeting.title
                renamingMeeting = meeting
            }
            .disabled(session.isProcessing(meeting))
            // See `Meeting.toggleKind()` for what conversion does and deliberately
            // doesn't do (issue #107), and `convertMeetingKind` for why this and
            // the detail view's toolbar button share one write instead of each
            // routing through their own general-purpose save. Guarded the same
            // way as "Delete" below — this mutates the same model a live
            // recording or an in-flight relabel pass could be touching underneath
            // it.
            Button(convertLabel(for: meeting)) {
                convertError = convertMeetingKind(meeting, context: context)
            }
            .disabled(!session.canDelete(meeting))
            // Disabled rather than hidden: a meeting that's mid-recording is still
            // the one you're most likely to right-click (it's at the top of the
            // list), and a missing item there reads as a bug rather than a rule.
            // `canDelete` also covers a relabel pass in flight from the detail
            // view — this row has no view of that on its own, so it has to defer
            // to the shared session state. See `CaptureSession.canDelete(_:)`.
            Button("Delete", role: .destructive) {
                deletingMeeting = meeting
            }
            .disabled(!session.canDelete(meeting))
        }
    }

    /// Comma-joined participant names for a row's subtitle, or `nil` when the
    /// meeting has none recorded — `nil` means the row shows no second line at all,
    /// never a fallback to something else. `participantNames` is set from the
    /// enrolled roster at capture start (`CaptureSession`) and editable afterward
    /// (`ParticipantRosterMenu`), so an older or ad-hoc meeting can legitimately
    /// have none.
    private func participantsSubtitle(for meeting: Meeting) -> String? {
        guard let names = meeting.participantNames, !names.isEmpty else { return nil }
        return names.joined(separator: ", ")
    }

    /// Start and stop live in the same place so stopping is as findable as starting.
    @ViewBuilder private var recordingControls: some View {
        switch session.state {
        case .idle:
            // Ad-hoc goes first: it's the common case, and burying it under a
            // calendar match is how a one-off got filed as "Connor - Chat coverage".
            Button {
                startRecording(event: nil, kind: .meeting)
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .font(.body.weight(.medium))
            }

            // A separate button, not a mode toggle on the one above: this mirrors
            // the menu bar's "Give Direction…" (issue #107 — directive capture
            // previously existed only there), which is itself a second button
            // rather than a picker for the same reason. Never offered against a
            // calendar event, same as the menu bar: a directive is you talking to
            // your agent, not a stand-in for whatever's on the calendar.
            Button {
                startRecording(event: nil, kind: .directive)
            } label: {
                Label("Give Direction…", systemImage: "text.bubble")
            }

            // A live calendar event is an offer, never a default.
            if let currentEvent {
                Button {
                    startRecording(event: currentEvent)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Use calendar event instead")
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                            Text(currentEvent.title)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: "calendar")
                    }
                }
            }

        case .preparingModel:
            Label("Preparing model…", systemImage: "arrow.down.circle")
                .foregroundStyle(Theme.Colors.textSecondary)

        case .recording:
            Button(role: .destructive) {
                Task { await session.stop(context: context) }
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        // Matches "Start recording"'s weight above — the label
                        // carries the meaning here, not the icon (#133).
                        Text("Stop recording")
                            .font(.body.weight(.medium))
                        if let startedAt = session.startedAt {
                            Text(startedAt, style: .timer)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                } icon: {
                    // A plain square, not the ring `stop.circle.fill` drew — the
                    // ring, in the same copper the brand mark uses, read as
                    // Cheerio's own logo rather than a control (maintainer
                    // feedback, #133). Dropping the ring is enough to tell them
                    // apart without giving up a conventional stop glyph.
                    Image(systemName: "stop.fill")
                }
            }
            // Copper, not red — red means failure, and this button appears
            // because a recording is healthy and in progress, not because
            // anything went wrong.
            .tint(Theme.Colors.recording)

            // The event that would have been offered in `.idle` above doesn't
            // disappear once capture starts — same row, just quiet and
            // unclickable now that starting is no longer the decision on the
            // table (#132). Shown whenever an event is current, not only when
            // this recording was started against it, matching the offer
            // above, which never checked that either.
            if let currentEvent {
                Label {
                    Text(currentEvent.title)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }

            // Reading an earlier meeting mid-call replaces the live view, so there has
            // to be a way back to it.
            if selection != nil {
                Button {
                    selection = nil
                } label: {
                    Label("Back to live transcript", systemImage: "waveform")
                }
            }

        case .holding:
            Button {
                Task { await session.confirmProcessing(context: context) }
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text("Process now")
                            .font(.body.weight(.medium))
                        if let deadline = session.holdDeadline {
                            // Counts down to the auto-process on its own, and
                            // tracks the deadline moving as edits extend it.
                            Text(deadline, style: .timer)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                } icon: {
                    Image(systemName: "sparkles")
                }
            }

            // Same escape hatch as `.recording` above: reading an earlier meeting
            // replaces the holding view, and the notes worth adding are behind it.
            if selection != nil {
                Button {
                    selection = nil
                } label: {
                    Label("Back to add notes", systemImage: "waveform")
                }
            }

        case .finishing:
            // The phase rather than a bare "Finishing up…": the same pipeline the
            // row indicators report on is what this state *is*, and a stage name
            // is the difference between "it's busy" and "it's stuck".
            ProcessingIndicator(label: finishingLabel, prominence: .section)
        }
    }

    /// What the `.finishing` control line says. Falls back to wording of its own
    /// only for the case `CaptureSession.stop(context:)` handles with no meeting at
    /// all — a recording whose meeting went away, which has no phase to report.
    private var finishingLabel: String {
        session.currentMeetingProcessingPhase?.label ?? "Finishing up…"
    }

    private var microphoneDenied: Binding<Bool> {
        Binding(
            get: { session.startFailure == .microphoneDenied },
            set: { if !$0 { session.startFailure = nil } }
        )
    }

    private var startFailed: Binding<Bool> {
        Binding(
            get: { session.startFailure?.message != nil },
            set: { if !$0 { session.startFailure = nil } }
        )
    }

    /// What the "Convert to…" context-menu item offers — the kind the meeting isn't,
    /// since converting is always a toggle.
    private func convertLabel(for meeting: Meeting) -> String {
        meeting.kind == .directive ? "Convert to Meeting" : "Convert to Directive"
    }

    /// Commits the "Delete" context-menu flow, after confirmation. Clears
    /// `selection` first when the deleted meeting is the one on screen — deleting
    /// out from under the detail view would otherwise leave it holding a model
    /// SwiftData just removed.
    private func performDelete() {
        guard let deletingMeeting else { return }
        defer { self.deletingMeeting = nil }
        let meetingID = deletingMeeting.persistentModelID
        if selection == deletingMeeting { selection = nil }
        do {
            // `context.container`, not `context` itself — see
            // `MeetingDeletion.delete(meetingID:container:)` for why this needs
            // its own context rather than the one this view shares with a
            // possibly in-flight recording.
            try MeetingDeletion.delete(meetingID: meetingID, container: context.container)
            session.meetingWasDeleted(meetingID)
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// Keeps `now` — and through it, the "Today"/"Yesterday" section titles —
    /// correct across midnight without anything else in the view needing to
    /// change. `.task` re-syncs `now` the moment this fires (covering a window
    /// reopened the next day, the `onAppear`-equivalent case), then loops:
    /// compute the next local midnight from whatever `now` actually is, sleep
    /// until then, update `now`, repeat.
    ///
    /// Computing the boundary from `now` on every pass — rather than sleeping a
    /// fixed 24 hours — is what makes this correct across a Mac sleeping through
    /// midnight. `Task.sleep(for:)` runs on `ContinuousClock`, which keeps
    /// advancing through machine sleep — but a suspended process doesn't get to
    /// run at the deadline, so the wake can be delivered well after the boundary
    /// it was aimed at. Re-deriving "midnight" from the real current time on
    /// every iteration, instead of trusting a stale target, keeps the section
    /// titles right no matter how late the wake lands.
    ///
    /// Two separate mechanisms handle a time-zone change, because they cover two
    /// different moments it can happen:
    /// - **Mid-sleep** (travel, a manual override, while this loop is already
    ///   parked in `Task.sleep`): re-reading `Calendar.current` on the next
    ///   iteration is too late — the sleep already computed its deadline under the
    ///   old zone, and nothing wakes it early. The view's `timeZoneID` state and its
    ///   `NSSystemTimeZoneDidChange` observer exist for exactly this: changing
    ///   `timeZoneID` cancels and restarts this `.task(id:)`, so the new zone takes
    ///   effect immediately instead of waiting out the stale deadline.
    /// - **Wake-after-suspend**, where the zone changed while the *process* wasn't
    ///   running to receive that notification at all: on wake, `Task.sleep` simply
    ///   resumes and the loop begins its next iteration — no restart involved — and
    ///   because `Calendar.current` is re-read inside the loop rather than hoisted
    ///   above it, that iteration derives the next boundary under whatever zone is
    ///   current the moment the Mac wakes.
    private func midnightRollover() async {
        while !Task.isCancelled {
            now = .now
            let calendar = Calendar.current
            guard
                let nextMidnight = calendar.nextDate(
                    after: now,
                    matching: DateComponents(hour: 0, minute: 0, second: 0),
                    matchingPolicy: .nextTime
                )
            else { return }
            let interval = nextMidnight.timeIntervalSince(now)
            try? await Task.sleep(for: .seconds(max(interval, 0)))
        }
    }

    /// `kind` defaults to `.meeting` so the calendar-event call site (never offered
    /// for a directive — see the button above) doesn't need to name it explicitly.
    ///
    /// The permission check and the `CaptureSession.start` call themselves live in
    /// ``RecordingStartFlow``, shared with the empty-state dashboard's matching
    /// buttons (#124) rather than duplicated here.
    private func startRecording(event: CalendarMeeting?, kind: MeetingKind = .meeting) {
        RecordingStartFlow.start(kind: kind, event: event, session: session, context: context, selection: $selection)
    }
}
