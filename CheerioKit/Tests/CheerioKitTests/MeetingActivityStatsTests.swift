import Foundation
import Testing

@testable import CheerioKit

/// What the empty-state dashboard's stat rows show (#124) — pure aggregation over
/// meetings the caller already has loaded, same shape as ``MeetingListGroupingTests``.
@Suite struct MeetingActivityStatsTests {
    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private static func date(
        _ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0, in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func meeting(
        startedAt: Date, endedAt: Date? = nil, followUps: Int = 0, actionable: Int = 0
    ) -> Meeting {
        let meeting = Meeting(title: "Meeting", startedAt: startedAt)
        meeting.endedAt = endedAt
        var items: [ActionItem] = []
        for _ in 0..<followUps {
            items.append(ActionItem(text: "Chase this", owner: "Guest", isOwner: false, disposition: .followUp))
        }
        for _ in 0..<actionable {
            items.append(ActionItem(text: "Do this", owner: "Me", isOwner: true, disposition: .actionable))
        }
        meeting.actionItems = items
        return meeting
    }

    @Test func countsOnlyMeetingsStartingInsideTheCurrentWeek() {
        let calendar = Self.calendar()
        // Wednesday, August 12, 2026 — the week runs Sunday the 9th through
        // Saturday the 15th under `firstWeekday: 1`.
        let now = Self.date(2026, 8, 12, in: calendar)
        let thisWeek = meeting(startedAt: Self.date(2026, 8, 9, in: calendar))
        let lastWeek = meeting(startedAt: Self.date(2026, 8, 8, in: calendar))

        let stats = MeetingActivityStats.compute(from: [thisWeek, lastWeek], now: now, calendar: calendar)
        #expect(stats.meetingsThisWeek == 1)
    }

    @Test func minutesComeFromActualElapsedTimeNotACalendarSlot() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 8, 12, in: calendar)
        let start = Self.date(2026, 8, 12, hour: 9, in: calendar)
        let ranLong = meeting(startedAt: start, endedAt: start.addingTimeInterval(90 * 60))

        let stats = MeetingActivityStats.compute(from: [ranLong], now: now, calendar: calendar)
        #expect(stats.minutesTranscribedThisWeek == 90)
    }

    @Test func abandonedRecordingsContributeNoMinutes() {
        // `endedAt == nil` means the app quit mid-recording — there is no real
        // duration to attribute, and guessing one would overstate the week.
        let calendar = Self.calendar()
        let now = Self.date(2026, 8, 12, in: calendar)
        let abandoned = meeting(startedAt: Self.date(2026, 8, 12, hour: 9, in: calendar), endedAt: nil)

        let stats = MeetingActivityStats.compute(from: [abandoned], now: now, calendar: calendar)
        #expect(stats.minutesTranscribedThisWeek == 0)
    }

    @Test func openFollowUpsIgnoreDispositionAndWeekBoundaryAlike() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 8, 12, in: calendar)
        // Well outside "this week" — a follow-up doesn't stop being open just
        // because the meeting that raised it did.
        let old = meeting(startedAt: Self.date(2026, 1, 1, in: calendar), followUps: 2, actionable: 1)
        let recent = meeting(startedAt: Self.date(2026, 8, 12, in: calendar), followUps: 1)

        let stats = MeetingActivityStats.compute(from: [old, recent], now: now, calendar: calendar)
        #expect(stats.openFollowUps == 3)
    }

    @Test func emptyLibraryReadsAsZeroesNotAnError() {
        let stats = MeetingActivityStats.compute(from: [], now: .now, calendar: Self.calendar())
        #expect(stats == MeetingActivityStats(meetingsThisWeek: 0, minutesTranscribedThisWeek: 0, openFollowUps: 0))
    }
}
