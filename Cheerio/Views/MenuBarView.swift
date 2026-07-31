import CheerioKit
import SwiftData
import SwiftUI

/// The menu-bar item's contents: start or stop without bringing the window forward.
struct MenuBarView: View {
    @Environment(CaptureSession.self) private var session
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow

    /// The calendar event happening right now, offered but never assumed.
    @State private var currentEvent: CalendarMeeting?

    var body: some View {
        Group {
            switch session.state {
            case .idle:
                Button("Start recording") { start(event: nil) }
                if let currentEvent {
                    Button("Record “\(currentEvent.title)”") { start(event: currentEvent) }
                }

            case .preparingModel:
                Text("Preparing model…")

            case .recording:
                if let meeting = session.meeting {
                    Text(meeting.title)
                }
                Button("Stop recording") {
                    Task { await session.stop(context: context) }
                }

            case .finishing:
                Text("Finishing up…")
            }

            Divider()
            Button("Open Cheerio") {
                openWindow(id: MenuBarView.mainWindowID)
            }
        }
        .task {
            while !Task.isCancelled {
                currentEvent = await CalendarService.shared.currentMeeting()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    static let mainWindowID = "main"

    /// Mirrors the sidebar's start action. Permission problems are surfaced in the
    /// window rather than here — a menu can't host an alert.
    private func start(event: CalendarMeeting?) {
        Task {
            guard await MicrophoneCapture.permission() == .granted else {
                openWindow(id: MenuBarView.mainWindowID)
                return
            }
            try? await session.start(
                title: event?.title ?? "Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))",
                calendarEventID: event?.id,
                context: context
            )
        }
    }
}

extension CaptureSession.State {
    /// Menu-bar symbol: filled while capturing so it reads at a glance.
    var menuBarSymbol: String {
        switch self {
        case .idle: "waveform"
        case .preparingModel: "arrow.down.circle"
        case .recording: "record.circle.fill"
        case .finishing: "ellipsis.circle"
        }
    }
}
