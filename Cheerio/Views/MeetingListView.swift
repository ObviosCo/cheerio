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
                        .foregroundStyle(.secondary)
                }
            } else if visibleMeetings.isEmpty, directivesOnly {
                Section("Meetings") {
                    Text("No directives yet.")
                        .foregroundStyle(.secondary)
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
        .task {
            await midnightRollover()
        }
        .alert("Rename meeting", isPresented: $renamingMeeting.presented()) {
            TextField("Meeting name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingMeeting = nil }
            Button("Save") { applyRename() }
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

    /// One row in the grouped list. The date now lives in the section header, so the
    /// subtitle only needs the time — that's true even in an absolute-date section,
    /// whose header already spells the date out in full, so repeating it on every row
    /// underneath would be redundant rather than disambiguating. Time-only is also
    /// the simpler, consistent choice: no branching on which kind of section a row
    /// happens to land in.
    @ViewBuilder private func row(for meeting: Meeting) -> some View {
        VStack(alignment: .leading) {
            HStack(spacing: 4) {
                Text(meeting.title).font(.headline)
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
            Text(meeting.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Without this the clickable area is only as wide as the title.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .tag(meeting)
        .contextMenu {
            Button("Rename") {
                renameText = meeting.title
                renamingMeeting = meeting
            }
        }
    }

    /// Start and stop live in the same place so stopping is as findable as starting.
    @ViewBuilder private var recordingControls: some View {
        switch session.state {
        case .idle:
            // Ad-hoc goes first: it's the common case, and burying it under a
            // calendar match is how a one-off got filed as "Connor - Chat coverage".
            Button {
                startRecording(event: nil)
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .font(.body.weight(.medium))
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
                                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)

        case .recording:
            Button(role: .destructive) {
                Task { await session.stop(context: context) }
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text("Stop recording")
                        if let startedAt = session.startedAt {
                            Text(startedAt, style: .timer)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "stop.circle.fill")
                }
            }
            .tint(.red)

            // Reading an earlier meeting mid-call replaces the live view, so there has
            // to be a way back to it.
            if selection != nil {
                Button {
                    selection = nil
                } label: {
                    Label("Back to live transcript", systemImage: "waveform")
                }
            }

        case .finishing:
            Label("Finishing up…", systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
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

    /// Commits the "Rename" context-menu flow. Plain SwiftData write, same as the
    /// live rename in `RecordingView` and the detail view — the only thing specific
    /// to this affordance is where the new text came from.
    private func applyRename() {
        defer { renamingMeeting = nil }
        guard let renamingMeeting else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        renamingMeeting.rename(to: trimmed)
        try? context.save()
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
    private func midnightRollover() async {
        let calendar = Calendar.current
        while !Task.isCancelled {
            now = .now
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

    private func startRecording(event: CalendarMeeting?) {
        Task {
            guard await MicrophoneCapture.permission() == .granted else {
                // Re-asking can't help once it's been denied, so offer the only
                // thing that can fix it.
                session.startFailure = .microphoneDenied
                return
            }
            // Don't leave a past meeting covering the detail column while the new one
            // spins up.
            selection = nil
            do {
                try await session.start(
                    title: event?.title ?? "Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))",
                    calendarEventID: event?.id,
                    context: context
                )
            } catch {
                session.startFailure = .failed(error.localizedDescription)
            }
        }
    }
}
