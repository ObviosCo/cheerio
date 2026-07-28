import CheerioKit
import SwiftData
import SwiftUI

struct MeetingListView: View {
    @Environment(CaptureSession.self) private var session
    @Environment(\.modelContext) private var context
    @Query(sort: \Meeting.startedAt, order: .reverse) private var meetings: [Meeting]

    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    startRecording()
                } label: {
                    Label(
                        session.state == .preparingModel ? "Preparing model…" : "Start recording",
                        systemImage: "record.circle"
                    )
                }
                .disabled(session.state != .idle)
            }

            Section("Meetings") {
                ForEach(meetings) { meeting in
                    NavigationLink(value: meeting.persistentModelID) {
                        VStack(alignment: .leading) {
                            Text(meeting.title).font(.headline)
                            Text(meeting.startedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationDestination(for: PersistentIdentifier.self) { id in
            if let meeting = meetings.first(where: { $0.persistentModelID == id }) {
                MeetingDetailView(meeting: meeting)
            }
        }
        .navigationTitle("Cheerio")
        .alert("Couldn't start recording", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func startRecording() {
        Task {
            guard await MicrophoneCapture.requestPermission() else {
                errorMessage = "Microphone access is required. Grant it in System Settings → Privacy."
                return
            }
            do {
                // TODO: pull title/eventID from CalendarService.currentMeeting()
                try await session.start(
                    title: "Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))",
                    calendarEventID: nil,
                    context: context
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
