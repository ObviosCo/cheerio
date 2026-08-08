import CheerioKit
import SwiftData
import SwiftUI

/// The menu-bar item's contents: start or stop without bringing the window forward.
struct MenuBarView: View {
    @Environment(CaptureSession.self) private var session
    @Environment(AppUpdater.self) private var updater
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow

    /// The calendar event happening right now, offered but never assumed.
    @State private var currentEvent: CalendarMeeting?

    var body: some View {
        Group {
            switch session.state {
            case .idle:
                Button("Start recording") { start(event: nil, kind: .meeting) }
                if let currentEvent {
                    Button("Record “\(currentEvent.title)”") { start(event: currentEvent, kind: .meeting) }
                }
                // Same pipeline as a meeting — both channels still record, per
                // RecordingMode's lesson (#12): kind drives routing, never capture.
                // Never offered against a calendar event: a directive is you talking
                // to your agent, not a stand-in for whatever's on the calendar.
                Button("Give Direction…") { start(event: nil, kind: .directive) }

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
            // The app menu has this too, but for someone who lives in the menu bar
            // that menu is behind an "Open Cheerio" first. Sparkle's own window
            // handles the rest, so it needs no state of its own here.
            Button("Check for Updates…") {
                updater.checkForUpdates()
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

    /// Mirrors the sidebar's start action. A menu can't host an alert, so failures are
    /// recorded on the session and the window is opened to present them — previously
    /// both the permission case and any startup error vanished, and the menu bar just
    /// dropped back to idle with no explanation.
    private func start(event: CalendarMeeting?, kind: MeetingKind) {
        Task {
            guard await MicrophoneCapture.permission() == .granted else {
                session.startFailure = .microphoneDenied
                openWindow(id: MenuBarView.mainWindowID)
                return
            }
            do {
                try await session.start(
                    title: event?.title ?? Self.autoTitle(for: kind),
                    calendarEventID: event?.id,
                    kind: kind,
                    context: context
                )
            } catch {
                session.startFailure = .failed(error.localizedDescription)
                openWindow(id: MenuBarView.mainWindowID)
            }
        }
    }

    /// A timestamped placeholder title, in the same "abbreviated date, short time"
    /// format regardless of kind — the difference is the label people scan for, not
    /// the clock format.
    private static func autoTitle(for kind: MeetingKind) -> String {
        let timestamp = Date.now.formatted(date: .abbreviated, time: .shortened)
        switch kind {
        case .meeting: return "Meeting \(timestamp)"
        case .directive: return "Direction — \(timestamp)"
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
