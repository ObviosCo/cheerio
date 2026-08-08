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
    /// A menu toggle rather than a section split: there aren't enough directives yet
    /// to earn their own part of the list, but hiding meetings while looking for one
    /// is already useful today.
    @State private var directivesOnly = false

    /// Matches title, rough notes, enhanced notes, and transcript text. The library
    /// is one person's meetings, so filtering in memory is cheaper than rebuilding
    /// the query on every keystroke.
    private var visibleMeetings: [Meeting] {
        let base = directivesOnly ? meetings.filter { $0.kind == .directive } : meetings
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { $0.matches(query) }
    }

    var body: some View {
        // Selection rather than a NavigationStack: a stack nested in the sidebar
        // pushed the meeting into the sidebar's own 280pt column and left the detail
        // column sitting on "No meeting selected".
        List(selection: $selection) {
            Section { recordingControls }

            Section("Meetings") {
                if visibleMeetings.isEmpty, !searchText.isEmpty {
                    Text("No meetings match “\(searchText)”.")
                        .foregroundStyle(.secondary)
                } else if visibleMeetings.isEmpty, directivesOnly {
                    Text("No directives yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(visibleMeetings) { meeting in
                    VStack(alignment: .leading) {
                        HStack(spacing: 4) {
                            Text(meeting.title).font(.headline)
                            if meeting.kind == .directive {
                                Text("Directive")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.tint.opacity(0.15), in: .capsule)
                            }
                        }
                        // Time as well as date: a busy day otherwise gives every row
                        // the same subtitle.
                        Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Without this the clickable area is only as wide as the title.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .tag(meeting)
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
