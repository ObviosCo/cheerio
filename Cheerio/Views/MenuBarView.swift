import AppKit
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

    /// Same persisted key `MeetingListView`'s sidebar picker binds — this is a second
    /// entry point onto the same setting, not a separate one, since the menu bar is
    /// how `NotificationService` and a from-idle user both actually start a recording.
    @AppStorage(RecordingMode.defaultsKey) private var recordingModeRaw = RecordingMode.default.rawValue

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

                // A submenu, not a segmented control: this is `MenuBarExtra`'s default
                // `.menu` style, which has no room for a segmented picker. Unadorned
                // `Picker` already renders as a checkable submenu in that context.
                Picker("Recording Mode", selection: $recordingModeRaw) {
                    ForEach(RecordingMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
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
                    calendarEventOccurrenceStart: event?.startDate,
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
    /// Menu-bar icon: the copper-ring brand mark (see `MenuBarIcon.swift`),
    /// not a stock SF Symbol — this is the one place the four session states
    /// map to their glyph, so `CheerioApp` just reads this property rather
    /// than switching on state itself.
    var menuBarIcon: NSImage {
        MenuBarIcon.image(for: self)
    }
}
