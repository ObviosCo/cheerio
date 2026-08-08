import Foundation
import Testing

@testable import CheerioKit

/// Pins "now," the timezone, and the week's first day so bucketing is deterministic —
/// none of these tests can pass or fail depending on when or where they run.
@Suite struct MeetingListGroupingTests {
    private static func calendar(firstWeekday: Int = 1, locale: Locale = Locale(identifier: "en_US")) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = firstWeekday
        calendar.locale = locale
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func todayAndYesterdayAreNamedRelativeToInjectedNow() {
        let calendar = Self.calendar()
        // Wednesday, August 12, 2026 — chosen only for a Sunday four days back
        // (August 9) that the week-boundary test below reuses.
        let now = Self.date(2026, 8, 12, hour: 10, in: calendar)
        let today = Meeting(title: "Standup", startedAt: Self.date(2026, 8, 12, hour: 9, in: calendar))
        let yesterday = Meeting(title: "1:1", startedAt: Self.date(2026, 8, 11, hour: 17, in: calendar))

        let sections = MeetingListGrouping.sections(for: [today, yesterday], now: now, calendar: calendar)

        #expect(sections.map(\.title) == ["Today", "Yesterday"])
        #expect(sections.map(\.meetings) == [[today], [yesterday]])
    }

    @Test func sameCalendarDayMeetingsShareOneSectionInGivenOrder() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 8, 12, hour: 20, in: calendar)
        let later = Meeting(title: "Standup", startedAt: Self.date(2026, 8, 12, hour: 15, in: calendar))
        let earlier = Meeting(title: "Kickoff", startedAt: Self.date(2026, 8, 12, hour: 9, in: calendar))

        // Reverse-chronological, as `@Query` already returns it — grouping must not
        // reorder within a day.
        let sections = MeetingListGrouping.sections(for: [later, earlier], now: now, calendar: calendar)

        #expect(sections.count == 1)
        #expect(sections[0].meetings == [later, earlier])
    }

    @Test func weekdayNameCoversTheRestOfASundayStartWeek() {
        let calendar = Self.calendar(firstWeekday: 1)  // Sunday-start week.
        let now = Self.date(2026, 8, 12, in: calendar)  // Wednesday.
        // August 9, 2026 is a Sunday, which opens the same Sun–Sat week as the 12th
        // under a Sunday-start calendar.
        let sunday = Meeting(title: "Planning", startedAt: Self.date(2026, 8, 9, in: calendar))

        let sections = MeetingListGrouping.sections(for: [sunday], now: now, calendar: calendar)

        #expect(sections.map(\.title) == ["Sunday"])
    }

    @Test func weekBoundaryRespectsTheCalendarsFirstWeekday() {
        // The same August 9, 2026 (Sunday) the test above puts in "this week" under a
        // Sunday-start calendar instead falls in the *previous* Mon–Sun week once the
        // week starts on Monday — the locale-safety the issue calls out by name.
        let calendar = Self.calendar(firstWeekday: 2)  // Monday-start week.
        let now = Self.date(2026, 8, 12, in: calendar)  // Wednesday.
        let sunday = Meeting(title: "Planning", startedAt: Self.date(2026, 8, 9, in: calendar))

        let sections = MeetingListGrouping.sections(for: [sunday], now: now, calendar: calendar)

        #expect(sections.map(\.title) != ["Sunday"])
    }

    @Test func olderMeetingsGetAnAbsoluteLocaleFormattedDate() {
        let calendar = Self.calendar(locale: Locale(identifier: "fr_FR"))
        let now = Self.date(2026, 8, 12, in: calendar)
        let old = Meeting(title: "Kickoff", startedAt: Self.date(2026, 1, 5, in: calendar))

        let sections = MeetingListGrouping.sections(for: [old], now: now, calendar: calendar)

        // "janv." (French for January, abbreviated) rather than a hand-rolled
        // English month — proof the label goes through `Date.FormatStyle`'s locale,
        // not a literal string.
        #expect(sections[0].title.localizedCaseInsensitiveContains("janv"))
    }

    @Test func dayBoundaryTimesDontLeakIntoTheWrongBucket() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 8, 12, hour: 0, in: calendar)
        // 23:59 the day before "now"'s midnight — one minute of wall-clock time away
        // from "today," but a full calendar day away.
        let lateLastNight = Meeting(title: "Late call", startedAt: Self.date(2026, 8, 11, hour: 23, in: calendar))

        let sections = MeetingListGrouping.sections(for: [lateLastNight], now: now, calendar: calendar)

        #expect(sections.map(\.title) == ["Yesterday"])
    }

    @Test func emptyInputProducesNoSections() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 8, 12, in: calendar)

        #expect(MeetingListGrouping.sections(for: [], now: now, calendar: calendar).isEmpty)
    }

    /// `sections(for:)` never looks at `kind` — the directives-only toggle in
    /// `MeetingListView` filters `visibleMeetings` *before* handing the result here,
    /// same as search. Grouping a pre-filtered directives-only list should bucket
    /// exactly like any other list of the same size and dates: no `.directive`-shaped
    /// branch to add, no meeting the filter dropped leaking into a section.
    @Test func groupsADirectivesOnlyFilteredListLikeAnyOtherList() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 8, 12, hour: 10, in: calendar)
        let directiveToday = Meeting(title: "Direction — today", startedAt: Self.date(2026, 8, 12, hour: 9, in: calendar))
        directiveToday.kind = .directive
        let meetingToday = Meeting(title: "Standup", startedAt: Self.date(2026, 8, 12, hour: 8, in: calendar))
        let directiveYesterday = Meeting(
            title: "Direction — yesterday",
            startedAt: Self.date(2026, 8, 11, hour: 17, in: calendar)
        )
        directiveYesterday.kind = .directive

        // What `visibleMeetings` computes when `directivesOnly` is on: filter first,
        // then hand the (smaller) result to grouping.
        let directivesOnly = [directiveToday, meetingToday, directiveYesterday].filter { $0.kind == .directive }
        let sections = MeetingListGrouping.sections(for: directivesOnly, now: now, calendar: calendar)

        #expect(sections.map(\.title) == ["Today", "Yesterday"])
        #expect(sections.map(\.meetings) == [[directiveToday], [directiveYesterday]])
    }

    @Test func defaultStrategyMatchesExplicitDateStrategy() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 8, 12, in: calendar)
        let meeting = Meeting(title: "Standup", startedAt: now)

        let withDefault = MeetingListGrouping.sections(for: [meeting], now: now, calendar: calendar)
        let withExplicitDate = MeetingListGrouping.sections(
            for: [meeting],
            strategy: .date,
            now: now,
            calendar: calendar
        )

        #expect(withDefault.map(\.title) == withExplicitDate.map(\.title))
    }
}
