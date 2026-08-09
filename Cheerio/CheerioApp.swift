import CheerioKit
import SwiftData
import SwiftUI

@main
struct CheerioApp: App {
    @State private var captureSession: CaptureSession

    /// Sparkle. Created with the session because it asks the session whether a
    /// recording is in progress before letting a scheduled check run.
    @State private var updater: AppUpdater

    /// One container shared by both scenes — `.modelContainer(for:)` on each would
    /// open two containers against the same store file.
    private let container: ModelContainer

    init() {
        // Ahead of everything else: if this copy is somewhere Sparkle could
        // never update it (a DMG mount, a translocated or still-quarantined
        // path — see issue #56), settle that before spending any effort on a
        // container or session that a relaunch or quit is about to discard.
        // A dev build from a build directory reads as none of those and
        // returns immediately.
        LaunchLocationCheck.runIfNeeded()

        // Ahead of everything else that could touch Application Support — the
        // session, the updater, and especially the store below — because moving a
        // directory out from under an already-open SQLite file corrupts it, and
        // reading meeting audio against the wrong container looks like data loss.
        // See BundleIdentifierMigration's doc comment for the full ordering argument.
        if BundleIdentifierMigration.migrateIfNeeded() == .failed {
            // The old container is still there and the new one isn't: keep every
            // path in this launch resolving against the old identifier rather than
            // open an empty new container and present that as the library. The next
            // launch retries the move on its own.
            AudioStorage.setContainerOverride(AudioStorage.legacyBundleIdentifier)
        }
        // Independent of the above: the defaults domain follows Bundle.main's own
        // identifier automatically, so this always targets the domain the app is
        // actually running under, whichever container it ended up open against.
        UserDefaultsMigration.migrateIfNeeded()

        let session = CaptureSession()
        _captureSession = State(initialValue: session)
        _updater = State(initialValue: AppUpdater(session: session))
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

        // Here, in `init()`, rather than in `ContentView`'s `.task` (where an
        // earlier version of this lived): that `.task` only ever runs once the
        // library renders, and `ContentView` renders the onboarding branch
        // instead whenever `OnboardingState.hasCompleted` is false — but
        // recording from the menu bar works before onboarding finishes, so a
        // crash during a pre-onboarding recording would stay `isInProgress`
        // until the person completed a walkthrough they might not open for
        // days. `init()` runs exactly once, before any window (onboarding or
        // library) exists and before `session` could possibly have started a
        // recording of its own — `excluding: session.meeting` is provably nil
        // here, kept only because the function's contract is the same either
        // way. `container.mainContext` is safe to touch synchronously here:
        // `CaptureSession` and `NotificationService` are both `@MainActor`, and
        // `NotificationService.shared.start` below is already called the same
        // way, with no `await`.
        StorageMigration.closeAbandonedRecordings(context: container.mainContext, excluding: session.meeting)

        // Here rather than in a `.task`, because this has to happen before the launch
        // finishes: the notification delegate and its action categories must exist by
        // then, or a click that *caused* the launch is delivered to nobody. This
        // prompts for nothing — notification permission is asked for lazily, at the
        // first moment something would actually be posted.
        NotificationService.shared.start(session: session, container: container)
    }

    var body: some Scene {
        // Two mechanisms, not one, because `.tint(_:)` in code turned out not to be
        // enough on its own (confirmed against a real build: `.borderedProminent`
        // buttons and `Toggle`s rendered system blue with only this modifier in
        // place). AppKit-bridged controls — `Toggle`, `TabView`'s selected-tab
        // chrome, `.borderedProminent` — read `NSColor.controlAccentColor`
        // directly, which SwiftUI's environment `.tint` doesn't reach; that only
        // comes from project.yml's `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`
        // (→ `NSAccentColorName` in the built `Info.plist`), naming this same
        // `Accent/Default` asset. `.tint(_:)` below is still needed for the
        // purely-SwiftUI reads that consult the environment value directly —
        // `AnyShapeStyle(.tint)` and `.foregroundStyle(.tint)` in
        // `OnboardingProgressDots`/`OnboardingHighlightRow`/`OnboardingScaffold`.
        // `Scene` has no `.tint(_:)` of its own (unlike `View`), so this lands on
        // each scene's content view individually rather than the App body once.
        //
        // Neither mechanism touches `RecordingRing`, which deliberately renders
        // from `.foreground`, never `.tint` (see that type's doc comment), or a
        // `role: .destructive` button, whose red is the button style's own default,
        // not sourced from the accent at all.
        Window("Cheerio", id: MenuBarView.mainWindowID) {
            ContentView()
                .environment(captureSession)
                .tint(Theme.Colors.accent)
                // Delivered by `ActivateInstalledCopy`, from a *different* (DMG
                // or translocated) launch of this same app asking this stable
                // copy to check for updates — see `CheckForUpdatesRequest`.
                // SwiftUI still delivers this even while the window itself is
                // closed (e.g. launched straight to the menu bar): the scene
                // exists, so its content's modifiers are live.
                .onOpenURL { url in
                    CheckForUpdatesRequest.handle(url, updater: updater)
                }
        }
        .modelContainer(container)
        // Always automatic: on macOS 26, conditioning this on
        // `OnboardingState.hasCompleted` (`.suppressed` on a first run) doesn't
        // reliably keep this window from claiming launch anyway — see #63. Rather
        // than fight that, `ContentView` embraces it and hands off to the
        // walkthrough itself, explicitly, from its own `onAppear`.
        .defaultLaunchBehavior(.automatic)
        .commands {
            // Where macOS apps put it: the app menu, right under "About Cheerio".
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
            CommandGroup(replacing: .help) {
                OpenOnboardingCommand()
            }
        }

        // The first-run walkthrough. Re-openable later from Settings and the Help
        // menu above, which is why it's a real window rather than a launch-time-only
        // sheet.
        //
        // Always suppressed: this window only ever opens because something asked
        // for it explicitly — `ContentView`'s first-run handoff, the Help menu
        // command above, or Settings — never because macOS decided to restore it.
        // That's what keeps a first run from ever showing both windows at once.
        Window("Welcome to Cheerio", id: OnboardingView.windowID) {
            OnboardingView()
                .environment(captureSession)
                .tint(Theme.Colors.accent)
        }
        .modelContainer(container)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)

        // Start and stop without surfacing the window — the state you need mid-call
        // is "is it recording", and that belongs in the menu bar.
        //
        // Custom label, not `systemImage:` — the glyph is the copper-ring brand
        // mark (see Views/MenuBarIcon.swift), not a stock SF Symbol. There's no
        // `MenuBarExtra` initializer that takes an `NSImage` directly, so the
        // label closure form is what makes `Image(nsImage:)` work here.
        MenuBarExtra {
            MenuBarView()
                .environment(captureSession)
                .environment(updater)
                .tint(Theme.Colors.accent)
        } label: {
            Image(nsImage: captureSession.state.menuBarIcon)
                // `NSImage.accessibilityDescription` doesn't propagate through
                // SwiftUI's `Image(nsImage:)` — VoiceOver needs the label on the
                // SwiftUI view itself, and it must track the state.
                .accessibilityLabel(captureSession.state.menuBarAccessibilityLabel)
        }
        .modelContainer(container)

        Settings {
            SettingsView()
                // Settings needs the session too: the callback tab's "run now"
                // button has to stay disabled while a recording is still being
                // finished — see `TranscriptCallbackSettingsView`.
                .environment(captureSession)
                .environment(updater)
                .tint(Theme.Colors.accent)
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    /// The past meeting on show. Nil means "the live recording if there is one,
    /// otherwise the placeholder" — the split view's detail column owns this, because
    /// pushing onto a stack inside the sidebar only ever filled the sidebar.
    @State private var selectedMeeting: Meeting?

    private let notifications = NotificationService.shared

    var body: some View {
        // Read right here, in `body`, to choose which branch renders — `hasCompleted`
        // backs a plain, non-observable `UserDefaults` flag, so this is the one place
        // in this view guaranteed to see a fresh answer; the `onAppear` below only
        // acts on whatever `body` already decided, it doesn't re-check.
        if OnboardingState.hasCompleted {
            library
        } else {
            // This window's `.defaultLaunchBehavior` is unconditionally `.automatic`
            // (see `CheerioApp`) because conditioning it on onboarding state doesn't
            // reliably keep it from opening on a first run anyway — macOS 26, #63. So
            // it renders nothing and hands off to the walkthrough instead of building
            // the sidebar, running its `@Query`, and showing library UI a first-run
            // user has no data for anyway. `dismiss()` runs before `openWindow`, not
            // after, so the walkthrough is never presented alongside this window —
            // only ever after it — and both happen in `onAppear` rather than `.task`,
            // the earliest synchronous point in this view's lifecycle, to close the
            // gap between this window's chrome appearing and this handoff firing as
            // tightly as SwiftUI's public API allows. A momentary zero-window gap
            // between the two calls is not a new state for this app — the menu bar
            // is already the primary surface and recording never requires a window
            // (see `docs/SPEC.md`) — so it isn't stranding anything that couldn't
            // already happen from the menu bar alone.
            //
            // What this can't fix: `.automatic` puts this window's `NSWindow` on
            // screen before any SwiftUI content code runs at all, so a first run can
            // still flash this window's chrome, blank, for a moment — no public
            // Window-scene API vetoes that from inside content. Documented as a known
            // residual on #63 rather than chased further here: the alternative that
            // would actually prevent it — suppressing both windows and deciding which
            // one opens from the `MenuBarExtra` label's own eager view instead —
            // replaces the launch mechanism this PR's CI run just confirmed works
            // (every non-onboarding screenshot depends on `.automatic` reliably
            // opening this window) with an unverified one, for every launch, to fix a
            // one-time cosmetic flash — not a trade to make blind, with no way to run
            // the app here to check it.
            Color.clear
                .onAppear {
                    dismiss()
                    openWindow(id: OnboardingView.windowID)
                }
        }
    }

    private var library: some View {
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
        // The "Open" action on a notes-ready notification lands on the service, which
        // isn't a view and so has no way to open a window or select anything. It
        // leaves the request here instead. Both hooks are needed: `onChange` for a
        // notification handled while this view is already up, and `onAppear` for the
        // click that opened the window in the first place, where the request was set
        // before this view existed.
        .onChange(of: notifications.meetingToOpen) { _, _ in openRequestedMeeting() }
        .onAppear {
            notifications.registerMainWindowOpener { openWindow(id: MenuBarView.mainWindowID) }
            openRequestedMeeting()
        }
        .task {
            // No-op unless the screenshot harness passed its launch arguments; see
            // `ScreenshotMode`. Here because it's the first point at which this
            // window exists to be resized.
            await ScreenshotMode.applyAtLaunch(openWindow: openWindow)
            // Only moves directories listed on a Meeting, never anything else in the
            // shared folder we used to write into.
            StorageMigration.migrateAudioIfNeeded(context: context)
            // Legacy rows carry no uuid, and the bundled MCP helper can't mint one
            // for them because it never writes. This process can.
            StorageMigration.backfillMeetingIDs(context: context)
            // `StorageMigration.closeAbandonedRecordings` used to run here too, but
            // this `.task` only fires once the library renders, which never happens
            // pre-onboarding — and recording from the menu bar works pre-onboarding,
            // so a crash there would stay `isInProgress` until someone opened a
            // walkthrough they might not for days. Moved to `CheerioApp.init()`,
            // which runs exactly once, before either window exists and before this
            // session could have recorded anything of its own to wrongly exclude.
            // Catches whatever MeetingDeletion.delete's own best-effort removal
            // didn't manage to remove — see AudioOrphanSweep for why that gap is
            // otherwise permanent rather than something a later run cleans up on
            // its own.
            _ = try? AudioOrphanSweep.sweep(context: context)
            // Refresh only — never prompt here. The onboarding walkthrough's
            // calendar step is what's allowed to show the TCC dialog; this just
            // picks up whatever the user already decided, there or in System
            // Settings, so `CalendarService`'s cached flag survives a relaunch.
            await CalendarService.shared.refreshAccessStatus()
            // Audio that aged out while the app was closed.
            _ = try? AudioRetentionService.purge(retention: .current, context: context)
        }
    }

    /// Selects the meeting a notification asked to open, and clears the request.
    ///
    /// Fetches everything and matches in memory rather than building a `#Predicate`
    /// over the optional `uuid`: the sidebar's `@Query` already holds every meeting
    /// this user has, so the rows are in the context either way, and this runs at
    /// most once per notification click. A request naming a meeting that no longer
    /// exists (deleted since the banner appeared) is dropped — the window is already
    /// coming forward, which is the useful half of the action.
    private func openRequestedMeeting() {
        guard let id = notifications.meetingToOpen else { return }
        notifications.meetingToOpen = nil
        let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        if let match = meetings.first(where: { $0.uuid == id }) {
            selectedMeeting = match
        }
    }

    /// A selected meeting wins over the live view: mid-call you sometimes need to
    /// look something up in an earlier meeting, and the sidebar offers a way back.
    @ViewBuilder private var detail: some View {
        if let selectedMeeting {
            MeetingDetailView(meeting: selectedMeeting) { self.selectedMeeting = nil }
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
