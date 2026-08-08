import CheerioKit
import SwiftData
import SwiftUI

@main
struct CheerioApp: App {
    @State private var captureSession = CaptureSession()

    /// One container shared by both scenes — `.modelContainer(for:)` on each would
    /// open two containers against the same store file.
    private let container: ModelContainer

    init() {
        do {
            let configuration = try ModelConfiguration(url: AudioStorage.storeURL())
            container = try ModelContainer(
                for: Meeting.self, TranscriptSegment.self, EnrolledSpeaker.self,
                configurations: configuration
            )
        } catch {
            // A local store we can't open leaves nothing to fall back to.
            fatalError("Couldn't open the local store: \(error)")
        }
    }

    var body: some Scene {
        Window("Cheerio", id: MenuBarView.mainWindowID) {
            ContentView()
                .environment(captureSession)
        }
        .modelContainer(container)
        // On a first run, the onboarding window claims launch instead — it opens
        // this one itself once it closes (see `OnboardingView.onDisappear`).
        // Evaluated once at process start, which is the only time it matters.
        .defaultLaunchBehavior(OnboardingState.hasCompleted ? .automatic : .suppressed)
        .commands {
            CommandGroup(replacing: .help) {
                OpenOnboardingCommand()
            }
        }

        // The first-run walkthrough. Re-openable later from Settings and the Help
        // menu above, which is why it's a real window rather than a launch-time-only
        // sheet.
        Window("Welcome to Cheerio", id: OnboardingView.windowID) {
            OnboardingView()
                .environment(captureSession)
        }
        .modelContainer(container)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(OnboardingState.hasCompleted ? .suppressed : .automatic)

        // Start and stop without surfacing the window — the state you need mid-call
        // is "is it recording", and that belongs in the menu bar.
        MenuBarExtra("Cheerio", systemImage: captureSession.state.menuBarSymbol) {
            MenuBarView()
                .environment(captureSession)
        }
        .modelContainer(container)

        Settings {
            SettingsView()
        }
        .modelContainer(container)
    }
}

/// A small view, not a bare closure, because `.commands` content needs its own
/// `openWindow` from the environment — the App type doesn't reliably vend one.
private struct OpenOnboardingCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Cheerio Walkthrough") {
            openWindow(id: OnboardingView.windowID)
        }
    }
}

struct ContentView: View {
    @Environment(CaptureSession.self) private var session
    @Environment(\.modelContext) private var context

    /// The past meeting on show. Nil means "the live recording if there is one,
    /// otherwise the placeholder" — the split view's detail column owns this, because
    /// pushing onto a stack inside the sidebar only ever filled the sidebar.
    @State private var selectedMeeting: Meeting?

    var body: some View {
        NavigationSplitView {
            MeetingListView(selection: $selectedMeeting)
                // The default sidebar is narrow enough that the two start buttons
                // truncate and read as one control — which is how a one-off session
                // got recorded against a calendar event.
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
        } detail: {
            detail
        }
        .onChange(of: session.state) { previous, state in
            switch state {
            case .recording:
                // A recording that just started is what you want to be looking at,
                // including when it was started from the menu bar.
                selectedMeeting = nil
            case .idle where previous == .finishing:
                // Notes are written by the time we're idle, so land on them instead of
                // the empty placeholder.
                selectedMeeting = session.lastFinishedMeeting
            default:
                break
            }
        }
        .task {
            // Only moves directories listed on a Meeting, never anything else in the
            // shared folder we used to write into.
            StorageMigration.migrateAudioIfNeeded(context: context)
            // Refresh only — never prompt here. The onboarding walkthrough's
            // calendar step is what's allowed to show the TCC dialog; this just
            // picks up whatever the user already decided, there or in System
            // Settings, so `CalendarService`'s cached flag survives a relaunch.
            await CalendarService.shared.refreshAccessStatus()
            // Audio that aged out while the app was closed.
            _ = try? AudioRetentionService.purge(retention: .current, context: context)
        }
    }

    /// A selected meeting wins over the live view: mid-call you sometimes need to
    /// look something up in an earlier meeting, and the sidebar offers a way back.
    @ViewBuilder private var detail: some View {
        if let selectedMeeting {
            MeetingDetailView(meeting: selectedMeeting)
        } else if session.state == .recording || session.state == .finishing {
            RecordingView()
        } else {
            ContentUnavailableView(
                "No meeting selected",
                systemImage: "text.bubble",
                description: Text("Select a past meeting or start recording.")
            )
        }
    }
}
