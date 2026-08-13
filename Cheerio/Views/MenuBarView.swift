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

    var body: some View {
        Group {
            switch session.state {
            case .idle:
                // Idle capture is not an idle app: launch recovery and a
                // re-identify pass both run a pipeline from here (issue #173).
                // Plain `Text`, like "Preparing model…" below — a menu renders
                // menu items, so the design system's spinner has no place in one;
                // the glyph above is what carries the motion here.
                if let phase = session.backgroundProcessingPhase {
                    Text(phase.label)
                    Divider()
                }
                Button("Start recording") { start(event: nil, kind: .meeting) }
                if let currentEvent {
                    Button("Record “\(currentEvent.title)”") { start(event: currentEvent, kind: .meeting) }
                }
                // Same pipeline as a meeting — both channels still record: kind
                // drives routing, never capture (a hard rule; see CLAUDE.md).
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

            case .holding:
                if let meeting = session.meeting {
                    Text(meeting.title)
                }
                // The one action the holding state needs from the menu bar: the
                // richer controls (notes, kind, callback) live in the window,
                // which "Open Cheerio" below already reaches.
                Button("Process now") {
                    Task { await session.confirmProcessing(context: context) }
                }

            case .finishing:
                // Which stage, when the pipeline has reached one — the same
                // reading the sidebar and the live view give, so the three can't
                // disagree about what's happening to the meeting that just ended.
                Text(session.currentMeetingProcessingPhase?.label ?? "Finishing up…")
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
    /// the clock format. Not `private`: `MeetingListView`'s matching start controls
    /// (issue #107) use this too, so the two entry points can't drift onto different
    /// wording for the same placeholder.
    static func autoTitle(for kind: MeetingKind) -> String {
        let timestamp = Date.now.formatted(date: .abbreviated, time: .shortened)
        switch kind {
        case .meeting: return "Meeting \(timestamp)"
        case .directive: return "Direction — \(timestamp)"
        }
    }
}

extension CaptureSession {
    /// What the menu bar depicts right now: the session's own state whenever
    /// there's capture to report, and otherwise whether a pipeline is running
    /// with nothing being captured — launch recovery or a re-identify pass, both
    /// of which run at `.idle` (issue #173). Capture wins the tie because a
    /// recording in progress is the one thing this glyph must never fail to show.
    ///
    /// This is the one place that decision is made, so `CheerioApp` reads a
    /// property rather than combining two pieces of session state itself.
    var menuBarStatus: MenuBarIcon.Status {
        state == .idle && isProcessingInBackground ? .processingInBackground : .session(state)
    }

    /// Menu-bar icon: the copper-ring brand mark (see `MenuBarIcon.swift`), not a
    /// stock SF Symbol.
    var menuBarIcon: NSImage {
        MenuBarIcon.image(for: menuBarStatus)
    }
}
