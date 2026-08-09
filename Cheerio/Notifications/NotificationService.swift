import AppKit
import CheerioKit
import Foundation
import OSLog
import SwiftData
import UserNotifications

/// The two desktop notifications from issue #51: an offer to record when a calendar
/// meeting starts, and a nudge when a finished recording's notes are ready.
///
/// Lives in the app target rather than `CheerioKit` because everything here is
/// macOS-app machinery — `UNUserNotificationCenter`, `NSApplication`, and the
/// recording start path. The part with an opinion worth testing (which events
/// deserve an offer, and the never-ask-twice ledger) is portable and lives in
/// `CheerioKit`'s `MeetingSuggestionPlanner`.
///
/// A singleton, like `CalendarService` and `TranscriptCallbackStatus`, for two
/// reasons that both come down to reach: `CaptureSession` has to be able to post
/// from deep inside `stop()` without threading a dependency through, and the
/// notification *delegate* has to exist before the app finishes launching so a click
/// that launched the app has somewhere to land. `CheerioApp.init` calls
/// ``start(session:container:)`` to hand it the two things it can't own.
@MainActor
@Observable
final class NotificationService {
    static let shared = NotificationService()

    /// Set when the user asks to open a meeting from a "notes are ready"
    /// notification. `ContentView` watches this, selects the meeting, and clears it.
    ///
    /// A pending request rather than a direct call because the main window may not
    /// exist at the moment the notification is handled — a click that cold-launches
    /// the app arrives before any view does. Leaving the id here means whichever
    /// view turns up first consumes it.
    var meetingToOpen: UUID?

    // MARK: Identifiers
    //
    // Categories are what carry the action buttons, and they're registered once at
    // launch. The action identifiers travel back in the response.

    private static let suggestionCategoryID = "app.cheerio.notification.meeting-suggestion"
    private static let notesReadyCategoryID = "app.cheerio.notification.notes-ready"
    private static let startRecordingActionID = "app.cheerio.notification.action.start-recording"
    private static let openMeetingActionID = "app.cheerio.notification.action.open-meeting"

    /// How often the day's events are re-read and the pending offers reconciled.
    ///
    /// This is not a poll for "has the meeting started" — the system answers that,
    /// from the `UNCalendarNotificationTrigger` attached to each request. This loop
    /// only asks a much slower question: has the calendar changed, has a recording
    /// started, is there anything newly inside the scheduling horizon.
    private static let reconcileInterval: Duration = .seconds(300)

    /// How long after an event's start the "Start Recording" button still means it.
    ///
    /// A banner can sit in Notification Centre indefinitely, and clicking one from
    /// two hours ago shouldn't file a fresh recording under a meeting that's over.
    private static let staleActionWindow: TimeInterval = 15 * 60

    private let log = Logger(subsystem: "app.cheerio.mac", category: "Notifications")
    private let center = UNUserNotificationCenter.current()
    /// `UNUserNotificationCenter.delegate` is weak, so this has to be held here.
    private let delegate = NotificationDelegate()

    private var session: CaptureSession?
    private var container: ModelContainer?
    private var ledger = SuggestionLedger.load()
    private var reconcileTask: Task<Void, Never>?
    /// Installed by the first view that has an `openWindow` in its environment.
    /// There is no non-view API for opening a SwiftUI `Window` scene, and the
    /// notification handlers are not views.
    private var openMainWindow: (() -> Void)?
    /// Reacts to the suggestion toggle going off without waiting for the next
    /// ``reconcileInterval`` tick. `UserDefaults` posts this notification for every
    /// write, not just this one key, so the handler re-checks the setting itself
    /// rather than trusting that it fired for the reason it cares about.
    private var defaultsObserver: NSObjectProtocol?

    private init() {}

    /// Wires the service to the app and starts watching the calendar.
    ///
    /// Called from `CheerioApp.init`, which is before `applicationDidFinishLaunching`
    /// — and that ordering is the requirement, not a convenience. The delegate has to
    /// be installed and the categories registered by the time the launch finishes, or
    /// a notification click that *caused* the launch is delivered to nobody and the
    /// action silently does nothing.
    ///
    /// Note what this does **not** do: ask for notification permission. Nothing here
    /// prompts. Authorization is requested at the first moment something would
    /// actually be posted — see ``ensureAuthorization()``.
    func start(session: CaptureSession, container: ModelContainer) {
        self.session = session
        self.container = container
        center.delegate = delegate
        center.setNotificationCategories([Self.suggestionCategory, Self.notesReadyCategory])
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcileCalendarSuggestions()
                try? await Task.sleep(for: Self.reconcileInterval)
            }
        }

        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.clearPendingSuggestionsIfDisabled()
            }
        }
    }

    /// Lets the notification handlers bring the main window forward. Views call this
    /// on appear; installing it more than once is harmless and deliberate, since the
    /// window that happens to exist first varies (onboarding on a first run, the
    /// library afterwards).
    func registerMainWindowOpener(_ opener: @escaping () -> Void) {
        openMainWindow = opener
    }

    // MARK: Categories

    private static var suggestionCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: suggestionCategoryID,
            actions: [
                UNNotificationAction(
                    identifier: startRecordingActionID,
                    title: "Start Recording",
                    // `.foreground` so acting on it brings Cheerio forward — the
                    // recording it starts is something you want to be able to see and
                    // stop, not something that happens invisibly behind whatever
                    // you're doing.
                    options: [.foreground]
                )
            ],
            intentIdentifiers: []
        )
    }

    private static var notesReadyCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: notesReadyCategoryID,
            actions: [
                UNNotificationAction(identifier: openMeetingActionID, title: "Open", options: [.foreground])
            ],
            intentIdentifiers: []
        )
    }

    // MARK: Calendar suggestions

    /// Re-reads today's events and reconciles the system's pending "record it?"
    /// offers against them: withdraws whatever no longer qualifies, queues whatever
    /// newly does. Every gate that means "not now" returns quietly — there is no
    /// state here that a user is waiting on.
    private func reconcileCalendarSuggestions() async {
        // The walkthrough owns the permission sequence on a first run, and it does
        // not include notifications. Scheduling here would fire the system's
        // notification prompt on top of the mic/system-audio/calendar dialogs the
        // walkthrough is deliberately pacing, from a window the user isn't looking
        // at. Nothing is lost by waiting: the loop comes back around.
        guard OnboardingState.hasCompleted else { return }
        guard NotificationSettings.suggestsRecording else {
            // The toggle may have just gone off with requests already sitting in the
            // system's pending queue — the reactive path in `clearPendingSuggestionsIfDisabled`
            // usually catches that faster, but this loop is the backstop.
            await removePendingSuggestionRequests(withPrefix: Self.suggestionRequestPrefix)
            return
        }
        guard let session else { return }

        // No calendar access means no suggestions, silently and permanently — the
        // permission is optional by design and this is not a place to ask for it.
        // `refreshAccessStatus` is the read that never prompts.
        guard await CalendarService.shared.refreshAccessStatus() else { return }

        // First diff pass, against whatever's true right now. Withdrawing a request
        // that no longer qualifies — its event was cancelled, deleted, moved, or
        // declined since it was offered, or a recording is now in the way — never
        // needs authorization, so it isn't gated on getting any: this runs every
        // tick regardless of whether anything new is worth adding. What it hands
        // back is only the candidates still needing a request.
        let toSchedule = await reconcilePendingSuggestionRequests(now: .now, session: session)
        guard !toSchedule.isEmpty else {
            ledger.save()
            return
        }

        // Only worth risking the system's permission prompt once there's actually
        // something to offer — this pre-auth pass exists purely to make that
        // decision, never to schedule anything itself.
        guard await ensureAuthorization() else { return }

        // `ensureAuthorization()` can sit open on the system's permission prompt for
        // as long as the user takes to answer it, so everything read above — the
        // setting, the recording context, the calendar candidates, the ledger — is
        // stale by the time it returns: a recording may have started, the toggle may
        // have flipped, or the calendar may have changed while the prompt was up.
        // Re-check the setting explicitly (a `false` here still means "clear
        // whatever's pending," same as the guard above), then redo the diff from
        // scratch — nothing computed before the `await` above is trusted for what
        // actually gets scheduled below.
        guard NotificationSettings.suggestsRecording else {
            await removePendingSuggestionRequests(withPrefix: Self.suggestionRequestPrefix)
            return
        }
        let scheduledAt = Date.now
        let freshToSchedule = await reconcilePendingSuggestionRequests(now: scheduledAt, session: session)

        // The `where` clause is what drops a suggestion that crossed all the way
        // past `grace` while the prompt was up: scheduling that one would either
        // silently do nothing (a calendar trigger for a date that's already gone) or
        // offer to record a meeting that's long since started.
        for suggestion in freshToSchedule
        where suggestion.startDate.addingTimeInterval(MeetingSuggestionPlanner.grace) > scheduledAt {
            await schedule(suggestion, now: scheduledAt)
        }
        ledger.save()
    }

    /// The recording context read live off `session`, for planning purposes.
    ///
    /// Both fields read the session, not the meeting's kind, and that's deliberate:
    /// a directive (#33) occupies the microphone exactly as a meeting does, so
    /// `isRecording` has to suppress offers during one — while its
    /// `calendarEventID` is always nil, since a directive is never started against
    /// an event, so nothing gets withdrawn on its account.
    ///
    /// `occurrenceStart` is paired with whichever of `meeting`/`lastFinishedMeeting`
    /// won above — never `meeting.startedAt`, which is when capture actually began
    /// and can drift seconds from the calendar occurrence's own start, which is
    /// what `MeetingSuggestion.occurrenceKey` is keyed on downstream. Getting that
    /// pairing wrong is exactly the bug this exists to avoid: a mismatch would
    /// either fail to withhold the offer for the occurrence just recorded, or
    /// (worse) suppress a *different* occurrence of the same recurring event.
    ///
    /// `session` is a class, so every read here is automatically live — there is no
    /// separate "re-fetch" step for staleness across a suspension to worry about,
    /// only calling this again after one to get today's answer instead of an
    /// earlier one.
    private func recordingContext(for session: CaptureSession) -> MeetingSuggestionPlanner.RecordingContext {
        let occurrenceStart =
            session.meeting != nil
            ? session.calendarEventOccurrenceStart : session.lastFinishedMeetingOccurrenceStart
        return MeetingSuggestionPlanner.RecordingContext(
            isRecording: session.state != .idle,
            eventID: (session.meeting ?? session.lastFinishedMeeting)?.calendarEventID,
            occurrenceStart: occurrenceStart
        )
    }

    /// Reconciles the system's pending suggestion requests against today's
    /// calendar, read fresh as of `now`: withdraws every pending request whose
    /// occurrence no longer qualifies, and returns the candidates that still need
    /// one, soonest first.
    ///
    /// Plans with `alreadyNotified: []` rather than the ledger's occurrence keys —
    /// deliberately, because a pending request's occurrence is *already* in the
    /// ledger (that's what got it scheduled in the first place), so filtering
    /// candidates by the ledger here would make every currently-pending occurrence
    /// look like it no longer qualifies and withdraw it on the spot. The ledger
    /// check happens only on the add side below, via `MeetingSuggestionPlanner
    /// .reconcile(pending:candidates:)`'s `toAdd`, which is where "never offer the
    /// same occurrence twice" actually belongs — `toAdd` is already "not currently
    /// pending," and the ledger narrows that to "and never was."
    ///
    /// An event that moved produces two effects here, not one that cancels the
    /// other: its old occurrence key drops out of the candidate set (a different
    /// start date means a different key — see `MeetingSuggestion.occurrenceKey`)
    /// and gets withdrawn, while its new occurrence key is a fresh candidate and
    /// gets added, in the same pass.
    private func reconcilePendingSuggestionRequests(
        now: Date, session: CaptureSession
    ) async -> [MeetingSuggestion] {
        ledger.prune(now: now)
        let candidates = MeetingSuggestionPlanner.suggestions(
            for: await CalendarService.shared.todaysMeetings(now: now),
            now: now,
            alreadyNotified: [],
            recording: recordingContext(for: session)
        )

        let pendingKeys = Set(
            await center.pendingNotificationRequests()
                .map(\.identifier)
                .filter { $0.hasPrefix(Self.suggestionRequestPrefix) }
                .map { String($0.dropFirst(Self.suggestionRequestPrefix.count)) }
        )
        let candidateKeys = Set(candidates.map(\.occurrenceKey))
        let diff = MeetingSuggestionPlanner.reconcile(pending: pendingKeys, candidates: candidateKeys)

        if !diff.toRemove.isEmpty {
            center.removePendingNotificationRequests(
                withIdentifiers: diff.toRemove.map(Self.suggestionRequestID(occurrenceKey:)))
            // A withdrawn offer was never seen — un-record it, or a still-eligible
            // occurrence (a meeting moved and moved back, a toggle flipped off and
            // on) stays blocked for the ledger's full retention window.
            ledger.remove(diff.toRemove)
            ledger.save()
        }

        return candidates.filter { diff.toAdd.contains($0.occurrenceKey) && !ledger.contains($0.occurrenceKey) }
    }

    private func schedule(_ suggestion: MeetingSuggestion, now: Date) async {
        let content = UNMutableNotificationContent()
        content.title = suggestion.title
        content.body = "Starting now — record it?"
        content.categoryIdentifier = Self.suggestionCategoryID
        // A silent banner at the default interruption level. Explicitly *not*
        // `.passive`, which would be quieter than the issue asks for: a passive
        // notification can go straight to Notification Centre without ever showing,
        // and an offer to record a meeting that only appears after the meeting is
        // over isn't an offer. Explicitly not `.timeSensitive` either — that breaks
        // through Focus, and nothing here is worth interrupting a Do Not Disturb for.
        // Silence is what makes it unobtrusive; the banner is the whole point.
        content.sound = nil
        content.interruptionLevel = .active
        content.userInfo = [
            UserInfoKey.eventID: suggestion.eventID,
            UserInfoKey.eventTitle: suggestion.title,
            UserInfoKey.eventStart: suggestion.startDate.timeIntervalSinceReferenceDate,
        ]

        // A calendar trigger rather than a time interval: it survives the Mac
        // sleeping through the gap, which for a meeting reminder is the normal case
        // rather than an edge one. A nil trigger delivers immediately, which is what
        // an event that started inside the grace window wants.
        var trigger: UNNotificationTrigger?
        if suggestion.fireDate > now {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: suggestion.fireDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }

        let request = UNNotificationRequest(
            identifier: Self.suggestionRequestID(occurrenceKey: suggestion.occurrenceKey),
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
            // Recorded on *scheduling*, not on delivery, which is what makes "never
            // twice" hold: there is no callback for delivery, and the horizon is
            // short enough (see `MeetingSuggestionPlanner.lookahead`) that a queued
            // offer is as good as a made one. Keyed by occurrence, not by the raw
            // event id — see `MeetingSuggestion.occurrenceKey`.
            ledger.record(suggestion.occurrenceKey, at: now)
        } catch {
            log.error("Couldn't schedule a recording suggestion: \(error, privacy: .public)")
        }
    }

    /// Every suggestion request's identifier starts with this, which is what makes
    /// prefix-based removal possible — `removePendingNotificationRequests` only
    /// takes exact identifiers, and an occurrence-keyed identifier isn't known ahead
    /// of time everywhere a suggestion request needs to be found and withdrawn.
    private static var suggestionRequestPrefix: String { "\(suggestionCategoryID)." }

    private static func suggestionRequestID(occurrenceKey: String) -> String {
        "\(suggestionRequestPrefix)\(occurrenceKey)"
    }

    /// Removes every pending suggestion request whose identifier starts with
    /// `prefix` — the whole suggestion category when the toggle just went off, or
    /// just one event's occurrences when a recording started against it.
    private func removePendingSuggestionRequests(withPrefix prefix: String) async {
        let pending = await center.pendingNotificationRequests()
        let matching = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard !matching.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: matching)
        // Withdrawn, not delivered — un-record so these occurrences can be offered
        // again if they become eligible before they start (the identifier is the
        // category prefix plus the occurrence key, so stripping the prefix recovers
        // the ledger key).
        ledger.remove(matching.map { String($0.dropFirst(Self.suggestionRequestPrefix.count)) })
        ledger.save()
    }

    /// The reactive half of the suggestion toggle: `reconcileCalendarSuggestions`
    /// catches "already off" on its own ``reconcileInterval`` cadence, but turning
    /// the toggle off shouldn't wait for that — a request scheduled minutes ago is
    /// still pending and would otherwise still show a banner for a feature the user
    /// just disabled. Cheap and idempotent rather than surgical: it's driven by
    /// every `UserDefaults` write, suggestion-related or not, and does nothing when
    /// the toggle is on.
    private func clearPendingSuggestionsIfDisabled() async {
        guard !NotificationSettings.suggestsRecording else { return }
        await removePendingSuggestionRequests(withPrefix: Self.suggestionRequestPrefix)
    }

    /// Withdraws every pending "record it?" offer the instant a recording begins.
    ///
    /// Called once, from `CaptureSession.startCapturing()` — the single place every
    /// recording path funnels through, whether it started from the menu bar, the
    /// library, a notification action, or onboarding — rather than duplicated at
    /// each of those call sites.
    ///
    /// This exists because ``reconcileCalendarSuggestions()``'s withdrawal is a
    /// backstop, not a guarantee: it only runs on its own ``reconcileInterval``
    /// cadence, so a request scheduled shortly before it fires can be delivered
    /// before that loop ever gets to it. `willPresent` (``presentationOptions(for:)``)
    /// catches a suggestion that fires *while already recording*, but only when
    /// Cheerio is frontmost to run it — the delegate method is foreground-only, so a
    /// banner delivered while the app is backgrounded skips it entirely and shows a
    /// "Start Recording" action for a slot that's already taken. Withdrawing right
    /// here, at the one moment a recording is guaranteed to have just started, closes
    /// that gap regardless of what's frontmost. `willPresent`'s suppression stays in
    /// place alongside this — it's what catches the case this hook can't: an offer
    /// for something other than the event just recorded, still sitting in the
    /// system's queue, delivered while a recording — any recording — is already in
    /// flight and none of it can be honoured.
    ///
    /// Every pending suggestion, not just the one tied to the event that started
    /// recording: Cheerio records one meeting at a time, so nothing else pending
    /// could be honoured either.
    func recordingDidStart() {
        Task { await removePendingSuggestionRequests(withPrefix: Self.suggestionRequestPrefix) }
    }

    // MARK: Notes ready

    /// Says that a finished recording has been transcribed and summarized.
    ///
    /// Called from `CaptureSession.stop` at the same readiness point as the
    /// transcript-ready callback, and deliberately after it. Returns immediately —
    /// the posting happens on its own task — because nothing about a banner may
    /// delay, gate, or fail the callback that external tooling is waiting on.
    func notifyNotesReady(title: String, meetingID: UUID) {
        guard NotificationSettings.announcesNotesReady else { return }
        // Don't tell someone about something they're already looking at. The window
        // updates itself the moment the session goes idle — `ContentView` selects the
        // finished meeting — so a banner on top of that is pure noise.
        guard !isShowingAWindow else { return }
        Task { await postNotesReady(title: title, meetingID: meetingID) }
    }

    private func postNotesReady(title: String, meetingID: UUID) async {
        guard await ensureAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Notes ready"
        content.subtitle = title
        content.body = "The transcript, speakers and notes are done."
        content.categoryIdentifier = Self.notesReadyCategoryID
        // Same shape as the suggestion above, for the same reasons: silent, default
        // interruption level, no Focus break-through.
        content.sound = nil
        content.interruptionLevel = .active
        content.userInfo = [UserInfoKey.meetingID: meetingID.uuidString]

        let request = UNNotificationRequest(
            identifier: "\(Self.notesReadyCategoryID).\(meetingID.uuidString)", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            log.error("Couldn't post the notes-ready notification: \(error, privacy: .public)")
        }
    }

    /// Whether Cheerio is frontmost with a real window on screen — i.e. whether the
    /// user is already looking at the app.
    ///
    /// `canBecomeMain` is the filter that matters: the menu-bar extra's status item
    /// has an `NSWindow` of its own and it's always "visible", so counting windows
    /// naively would report the app as on-screen for someone who only ever uses the
    /// menu bar — which is exactly the person this notification exists for.
    /// A nil session means `start(session:container:)` hasn't run, which can't happen
    /// once the app has launched — but it reads as "not recording" rather than as a
    /// reason to swallow a notification, because swallowing is the worse failure.
    private var isRecording: Bool { (session?.state ?? .idle) != .idle }

    private var isShowingAWindow: Bool {
        NSApplication.shared.isActive
            && NSApplication.shared.windows.contains { $0.isVisible && $0.canBecomeMain }
    }

    // MARK: Authorization

    /// Asks for notification permission the first time something would actually be
    /// posted, and never before.
    ///
    /// Not at launch, and not in the walkthrough: a permission dialog is only fair
    /// when the thing it's for is about to happen, and at launch nothing is. In
    /// practice this lands within half an hour of a real calendar meeting, or right
    /// after a recording finishes processing — both moments where "Cheerio wants to
    /// send you notifications" answers a question the user can see.
    ///
    /// A denial is final and silent. Nothing retries, nothing badges Settings, and
    /// every caller above treats `false` as "skip this" rather than as an error.
    private func ensureAuthorization() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            // Alerts only. No badge (there's no count worth showing) and no sound
            // (the issue's "unobtrusive" bar), so the prompt asks for the narrowest
            // thing that makes either notification work.
            do {
                return try await center.requestAuthorization(options: [.alert])
            } catch {
                log.error("Notification authorization request failed: \(error, privacy: .public)")
                return false
            }
        default:
            return false
        }
    }

    /// Whether macOS has been told no. Settings asks this so it can explain why the
    /// toggles look inert; nothing else acts on it, and nothing anywhere retries the
    /// request on the strength of it.
    func isDeniedBySystem() async -> Bool {
        await authorizationStatus() == .denied
    }

    /// Reads the status through the completion-handler API on purpose: the `async`
    /// spelling hands back the whole `UNNotificationSettings` object, which is not
    /// `Sendable` and so can't cross back into this actor under strict concurrency.
    /// Pulling the one enum out inside the callback keeps what crosses to a value.
    private func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0.authorizationStatus) }
        }
    }

    // MARK: Responses

    /// What should be shown for a notification that arrives while Cheerio is running.
    ///
    /// The "already looking at it" suppression for notes-ready happens at post time,
    /// in ``notifyNotesReady(title:meetingID:)``; this repeats it because the two
    /// moments aren't the same one — the user can bring the window forward in the gap
    /// between posting and presentation. A recording suggestion that arrives while a
    /// recording is already in flight is likewise withdrawn rather than shown: the
    /// offer couldn't be honoured.
    fileprivate func presentationOptions(for categoryID: String) -> UNNotificationPresentationOptions {
        switch categoryID {
        case Self.notesReadyCategoryID where isShowingAWindow:
            return []
        case Self.suggestionCategoryID where isRecording:
            return []
        default:
            // `.list` as well as `.banner` so a missed offer is still in Notification
            // Centre rather than gone.
            return [.banner, .list]
        }
    }

    fileprivate func handle(_ response: NotificationResponse) async {
        switch response.categoryID {
        case Self.suggestionCategoryID:
            // Only the button starts anything. Clicking the body of a notification is
            // "show me this", and a stray click on a banner is far too cheap a way to
            // start recording a room.
            guard response.actionID == Self.startRecordingActionID else {
                activateAndShowMainWindow()
                return
            }
            await startRecording(for: response)

        case Self.notesReadyCategoryID:
            // Here the button and the body mean the same thing, because the only
            // thing this notification offers is to look at the meeting.
            guard response.actionID != UNNotificationDismissActionIdentifier else { return }
            meetingToOpen = response.meetingID
            activateAndShowMainWindow()

        default:
            break
        }
    }

    /// Mirrors `MenuBarView.start(event:kind:)` — the same permission check, the same
    /// title/`calendarEventID` pair, the same "a failure has to survive long enough
    /// for the window to present it" handling. Always `.meeting`: every suggestion
    /// here comes from a calendar event, and a directive (#33) is you talking to the
    /// app on your own, never something the calendar can propose. The context is the
    /// `mainContext`, which is the very context the views are bound to, so a
    /// recording started from a notification appears in a library window that isn't
    /// open yet.
    private func startRecording(for response: NotificationResponse) async {
        guard let session, let container else { return }
        guard session.state == .idle else {
            activateAndShowMainWindow()
            return
        }
        // The click may be arriving long after the banner appeared — from Notification
        // Centre, or after a relaunch. Recording an hour-old meeting under its title
        // would file a fragment as the whole thing.
        if let start = response.eventStart, Date.now > start.addingTimeInterval(Self.staleActionWindow) {
            log.notice("Ignoring a stale recording suggestion and opening the window instead")
            activateAndShowMainWindow()
            return
        }

        guard await MicrophoneCapture.permission() == .granted else {
            session.startFailure = .microphoneDenied
            activateAndShowMainWindow()
            return
        }
        do {
            try await session.start(
                title: response.eventTitle ?? "Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))",
                calendarEventID: response.eventID,
                calendarEventOccurrenceStart: response.eventStart,
                kind: .meeting,
                context: container.mainContext
            )
            // `.foreground` on the notification action activates the app process,
            // but Cheerio is menu-bar-only: it does not reopen a SwiftUI `Window`
            // scene that's been closed. Without this, a recording started from a
            // notification has no visible window with a Stop button in it.
            activateAndShowMainWindow()
        } catch {
            session.startFailure = .failed(error.localizedDescription)
            activateAndShowMainWindow()
        }
    }

    private func activateAndShowMainWindow() {
        NSApplication.shared.activate()
        // Nil only if no view has ever appeared — which for a click that cold-launched
        // the app means the window is opening anyway, under `defaultLaunchBehavior`.
        openMainWindow?()
    }
}

/// The `userInfo` keys shared by what the service writes into a notification and
/// what `NotificationResponse` reads back out of one.
///
/// At file scope rather than nested in the service, and that's not tidiness: a
/// `static let` on a `@MainActor` type is main-actor-isolated too, and the unpacking
/// below happens in the delegate *before* the hop to the main actor. One spelling,
/// two directions, reachable from both.
private enum UserInfoKey {
    static let eventID = "eventID"
    static let eventTitle = "eventTitle"
    static let eventStart = "eventStart"
    static let meetingID = "meetingID"
}

/// The Sendable half of a `UNNotificationResponse`.
///
/// `UNNotification` and `UNNotificationResponse` are neither `Sendable` nor
/// main-actor-bound, so they cannot be handed to ``NotificationService`` directly.
/// Everything the service needs is a handful of strings and a date, so the delegate
/// unpacks them at the boundary.
private struct NotificationResponse: Sendable {
    let categoryID: String
    let actionID: String
    let eventID: String?
    let eventTitle: String?
    let eventStart: Date?
    let meetingID: UUID?

    init(categoryID: String, actionID: String, userInfo: [AnyHashable: Any]) {
        self.categoryID = categoryID
        self.actionID = actionID
        eventID = userInfo[UserInfoKey.eventID] as? String
        eventTitle = userInfo[UserInfoKey.eventTitle] as? String
        eventStart = (userInfo[UserInfoKey.eventStart] as? Double)
            .map(Date.init(timeIntervalSinceReferenceDate:))
        meetingID = (userInfo[UserInfoKey.meetingID] as? String).flatMap(UUID.init(uuidString:))
    }
}

/// A separate object from the service so the service doesn't have to be an
/// `NSObject`, and so the isolation hop happens in exactly one place — the delegate
/// callbacks are handed non-`Sendable` UserNotifications types, and unpacking them
/// here is what lets the service stay `@MainActor`.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let categoryID = notification.request.content.categoryIdentifier
        return await NotificationService.shared.presentationOptions(for: categoryID)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let unpacked = NotificationResponse(
            categoryID: response.notification.request.content.categoryIdentifier,
            actionID: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
        await NotificationService.shared.handle(unpacked)
    }
}
