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
    /// The calendar event happening right now, offered as a title but never assumed.
    @State private var currentEvent: CalendarMeeting?

    /// Matches title, rough notes, enhanced notes, and transcript text. The library
    /// is one person's meetings, so filtering in memory is cheaper than rebuilding
    /// the query on every keystroke.
    private var visibleMeetings: [Meeting] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings }
        return meetings.filter { $0.matches(query) }
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
        MeetingListGrouping.sections(for: visibleMeetings)
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
            } else {
                // One `Section` per date bucket instead of a single flat "Meetings"
                // section — empty buckets never appear because grouping only ever
                // produces a section for a day that has something in it.
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
        .task {
            // Keep the calendar offer fresh as events start and end.
            while !Task.isCancelled {
                currentEvent = await CalendarService.shared.currentMeeting()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // Both alerts read the session, not local state, so a recording started from the
        // menu bar can explain itself here.
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
                // Nothing creates directives yet, so this is dormant today —
                // it only needs to be visible once something does.
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
