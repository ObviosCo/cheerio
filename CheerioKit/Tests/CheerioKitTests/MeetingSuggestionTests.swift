import Foundation
import Testing

@testable import CheerioKit

/// Which calendar events earn a "record it?" notification, and the dedup that keeps
/// one meeting from asking twice (issue #51). Everything here is the pure half —
/// nothing touches `UNUserNotificationCenter` or EventKit.
@Suite struct MeetingSuggestionTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func event(
        id: String = "event-1",
        title: String = "Standup",
        startsIn offset: TimeInterval,
        lasting duration: TimeInterval = 1800,
        isAllDay: Bool = false,
        isDeclined: Bool = false
    ) -> CalendarMeeting {
        let start = now.addingTimeInterval(offset)
        return CalendarMeeting(
            id: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            isAllDay: isAllDay,
            isDeclined: isDeclined
        )
    }

    private func plan(
        _ meetings: [CalendarMeeting],
        alreadyNotified: Set<String> = [],
        recording: MeetingSuggestionPlanner.RecordingContext = .idle
    ) -> [MeetingSuggestion] {
        MeetingSuggestionPlanner.suggestions(
            for: meetings,
            now: now,
            alreadyNotified: alreadyNotified,
            recording: recording
        )
    }

    @Test func suggestsAnEventStartingInsideTheLookahead() {
        let suggestions = plan([event(startsIn: 600)])
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.title == "Standup")
        // Still in the future, so it's scheduled for its own start time rather than
        // delivered now.
        #expect(suggestions.first?.fireDate == now.addingTimeInterval(600))
    }

    @Test func firesImmediatelyForAnEventAlreadyUnderWay() {
        let suggestions = plan([event(startsIn: -60)])
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.fireDate == now)
    }

    @Test func ignoresEventsBeyondTheLookahead() {
        #expect(plan([event(startsIn: MeetingSuggestionPlanner.lookahead + 60)]).isEmpty)
    }

    @Test func ignoresEventsThatStartedTooLongAgo() {
        #expect(plan([event(startsIn: -MeetingSuggestionPlanner.grace - 60)]).isEmpty)
    }

    @Test func ignoresEventsThatHaveAlreadyEnded() {
        #expect(plan([event(startsIn: -60, lasting: 30)]).isEmpty)
    }

    @Test func ignoresZeroLengthMarkers() {
        #expect(plan([event(startsIn: 300, lasting: 0)]).isEmpty)
    }

    @Test func ignoresAllDayEvents() {
        #expect(plan([event(startsIn: 300, isAllDay: true)]).isEmpty)
    }

    @Test func ignoresDeclinedOrCancelledEvents() {
        #expect(plan([event(startsIn: 300, isDeclined: true)]).isEmpty)
    }

    @Test func neverOffersTheSameEventTwice() {
        #expect(plan([event(id: "already", startsIn: 300)], alreadyNotified: ["already"]).isEmpty)
    }

    @Test func offersNothingWhileARecordingIsInFlight() {
        // Not just the event being recorded: Cheerio records one meeting at a time,
        // so any offer made now is one it couldn't honour.
        let meetings = [event(id: "being-recorded", startsIn: -60), event(id: "another", startsIn: 300)]
        #expect(plan(meetings, recording: .recording(eventID: "being-recorded")).isEmpty)
    }

    @Test func skipsTheEventLinkedToTheLastRecordingEvenOnceIdle() {
        // Stopping early — a call that ran short — shouldn't re-offer the meeting you
        // just recorded while its slot is still on the calendar.
        let context = MeetingSuggestionPlanner.RecordingContext(isRecording: false, eventID: "being-recorded")
        let suggestions = plan(
            [event(id: "being-recorded", startsIn: -60), event(id: "another", startsIn: 300)],
            recording: context
        )
        #expect(suggestions.map(\.eventID) == ["another"])
    }

    @Test func sortsBySoonestFirst() {
        let suggestions = plan([event(id: "later", startsIn: 900), event(id: "sooner", startsIn: 120)])
        #expect(suggestions.map(\.eventID) == ["sooner", "later"])
    }
}

@Suite struct SuggestionLedgerTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func recordsAndReportsAnEvent() {
        var ledger = SuggestionLedger()
        #expect(!ledger.contains("event-1"))
        ledger.record("event-1", at: now)
        #expect(ledger.contains("event-1"))
        #expect(ledger.eventIDs == ["event-1"])
    }

    @Test func prunesEntriesPastTheirRetention() {
        var ledger = SuggestionLedger()
        ledger.record("yesterday", at: now.addingTimeInterval(-SuggestionLedger.retention - 60))
        ledger.record("recent", at: now.addingTimeInterval(-60))
        ledger.prune(now: now)
        #expect(ledger.eventIDs == ["recent"])
    }

    @Test func roundTripsThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "MeetingSuggestionTests.\(UUID().uuidString)"))
        defer { defaults.removeObject(forKey: SuggestionLedger.defaultsKey) }

        var ledger = SuggestionLedger()
        ledger.record("event-1", at: now)
        ledger.save(to: defaults)

        let loaded = SuggestionLedger.load(from: defaults)
        #expect(loaded.contains("event-1"))
        // Reloading must not resurrect anything the pruner would have dropped.
        var pruned = loaded
        pruned.prune(now: now.addingTimeInterval(SuggestionLedger.retention + 60))
        #expect(pruned.eventIDs.isEmpty)
    }

    @Test func loadsEmptyWhenNothingWasEverSaved() throws {
        let defaults = try #require(UserDefaults(suiteName: "MeetingSuggestionTests.\(UUID().uuidString)"))
        #expect(SuggestionLedger.load(from: defaults).eventIDs.isEmpty)
    }
}

@Suite struct NotificationSettingsTests {
    /// The one thing worth pinning: an unset key means "on", not "off". Both toggles
    /// ship on, and `UserDefaults.bool(forKey:)` would read never-asked as declined.
    @Test func bothNotificationsDefaultOn() {
        let defaults = UserDefaults.standard
        let suggest = defaults.object(forKey: NotificationSettings.suggestRecordingKey)
        let ready = defaults.object(forKey: NotificationSettings.notesReadyKey)
        defer {
            defaults.set(suggest, forKey: NotificationSettings.suggestRecordingKey)
            defaults.set(ready, forKey: NotificationSettings.notesReadyKey)
        }

        defaults.removeObject(forKey: NotificationSettings.suggestRecordingKey)
        defaults.removeObject(forKey: NotificationSettings.notesReadyKey)
        #expect(NotificationSettings.suggestsRecording)
        #expect(NotificationSettings.announcesNotesReady)

        defaults.set(false, forKey: NotificationSettings.suggestRecordingKey)
        defaults.set(false, forKey: NotificationSettings.notesReadyKey)
        #expect(!NotificationSettings.suggestsRecording)
        #expect(!NotificationSettings.announcesNotesReady)
    }
}
