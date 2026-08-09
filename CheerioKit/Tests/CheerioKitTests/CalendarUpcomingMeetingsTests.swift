import Foundation
import Testing

@testable import CheerioKit

/// The pure half of ``CalendarService/upcomingMeetings(now:horizon:limit:)`` — the
/// filtering, ordering, and limiting that don't need an `EKEventStore` behind them.
@Suite struct CalendarUpcomingMeetingsTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func meeting(
        id: String, title: String = "Meeting", startsIn offset: TimeInterval, isDeclined: Bool = false
    ) -> CalendarMeeting {
        let start = now.addingTimeInterval(offset)
        return CalendarMeeting(
            id: id, title: title, startDate: start, endDate: start.addingTimeInterval(1800), isAllDay: false,
            isDeclined: isDeclined
        )
    }

    @Test func dropsDeclinedEventsAndKeepsTheRest() {
        let meetings = [meeting(id: "kept", startsIn: 300), meeting(id: "declined", startsIn: 600, isDeclined: true)]
        let result = CalendarService.filterUpcoming(meetings, now: now, limit: 5)
        #expect(result.map(\.id) == ["kept"])
    }

    @Test func dropsEventsThatAlreadyStarted() {
        let meetings = [meeting(id: "past", startsIn: -60), meeting(id: "future", startsIn: 60)]
        let result = CalendarService.filterUpcoming(meetings, now: now, limit: 5)
        #expect(result.map(\.id) == ["future"])
    }

    @Test func sortsSoonestFirst() {
        let meetings = [meeting(id: "later", startsIn: 900), meeting(id: "sooner", startsIn: 120)]
        let result = CalendarService.filterUpcoming(meetings, now: now, limit: 5)
        #expect(result.map(\.id) == ["sooner", "later"])
    }

    @Test func capsAtTheGivenLimit() {
        let meetings = (0..<10).map { meeting(id: "\($0)", startsIn: TimeInterval($0 * 60)) }
        let result = CalendarService.filterUpcoming(meetings, now: now, limit: 3)
        #expect(result.count == 3)
    }

    /// The regression this suite exists for: `Array.prefix(_:)` traps on a negative
    /// count, and a negative `limit` is a value this public API can be handed —
    /// clamping to zero must hold, not just "some non-crashing count."
    @Test func negativeLimitClampsToZeroInsteadOfTrapping() {
        let meetings = [meeting(id: "one", startsIn: 300)]
        let result = CalendarService.filterUpcoming(meetings, now: now, limit: -1)
        #expect(result.isEmpty)
    }

    @Test func zeroLimitReturnsNothing() {
        let meetings = [meeting(id: "one", startsIn: 300)]
        #expect(CalendarService.filterUpcoming(meetings, now: now, limit: 0).isEmpty)
    }
}
