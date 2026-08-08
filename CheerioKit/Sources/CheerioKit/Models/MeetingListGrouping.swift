import Foundation

/// Which axis the meeting list groups by. `.date` is the only strategy today;
/// grouping by project (#1) is expected to add a case here later without touching
/// call sites that already pass `.date` explicitly — the missing piece for that is a
/// picker in the UI, not this enum or ``MeetingListGrouping/sections(for:strategy:now:calendar:)``.
public enum MeetingListGroupingStrategy: Sendable {
    case date
}

/// One labeled section of the meeting list, in display order.
public struct MeetingListSection: Identifiable, Equatable {
    /// Derived from the bucket, not from `title`: two absolute-date sections a year
    /// apart can share a weekday label, and `List`/`ForEach` need an id that doesn't
    /// collide when that happens.
    public let id: String
    public let title: String
    public let meetings: [Meeting]

    public init(id: String, title: String, meetings: [Meeting]) {
        self.id = id
        self.title = title
        self.meetings = meetings
    }
}

/// Buckets an already-filtered, reverse-chronological meeting list into the sections
/// the library view shows.
///
/// This only groups and labels — it never filters. Callers (search, the
/// directives-only toggle, and anything layered on top of them later) run first, and
/// hand their result here; a day with nothing left in it simply never produces a
/// section, so "empty sections don't render" falls out of the bucketing rather than
/// needing a separate check downstream.
public enum MeetingListGrouping {
    /// - Parameters:
    ///   - meetings: Already filtered, in the order sections should preserve within a
    ///     bucket (reverse-chronological, in practice — the order `@Query` already
    ///     returns).
    ///   - now: Injected rather than defaulting to `Date()` internally so tests can pin
    ///     "today."
    ///   - calendar: Injected rather than `.current` so tests can pin both the
    ///     first-weekday-of-the-week (locale-dependent) and the reference timezone.
    public static func sections(
        for meetings: [Meeting],
        strategy: MeetingListGroupingStrategy = .date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [MeetingListSection] {
        switch strategy {
        case .date:
            return dateSections(for: meetings, now: now, calendar: calendar)
        }
    }

    private static func dateSections(for meetings: [Meeting], now: Date, calendar: Calendar) -> [MeetingListSection] {
        guard !meetings.isEmpty else { return [] }
        let startOfNow = calendar.startOfDay(for: now)

        // A dictionary keyed by day-start groups meetings that land on the same
        // calendar day even if they aren't adjacent in `meetings`; `order` remembers
        // which day each bucket was first seen on, so sections come out in the same
        // reverse-chronological order the input arrived in.
        var order: [Date] = []
        var buckets: [Date: [Meeting]] = [:]
        for meeting in meetings {
            let dayStart = calendar.startOfDay(for: meeting.startedAt)
            if buckets[dayStart] == nil { order.append(dayStart) }
            buckets[dayStart, default: []].append(meeting)
        }

        return order.map { dayStart in
            MeetingListSection(
                id: String(Int(dayStart.timeIntervalSinceReferenceDate)),
                title: title(for: dayStart, startOfNow: startOfNow, calendar: calendar),
                meetings: buckets[dayStart] ?? []
            )
        }
    }

    /// Today / Yesterday / this week's weekday name / an absolute date — in that
    /// priority order.
    ///
    /// `Calendar.isDateInToday`/`isDateInYesterday` read the real wall clock, not an
    /// injectable reference date, so they can't be pinned in a test; comparing
    /// `dayStart` against the caller-supplied `startOfNow` with
    /// `dateComponents(_:from:to:)` is the same idea, made deterministic.
    ///
    /// "Today"/"Yesterday" go through `String(localized:)` rather than
    /// `RelativeDateTimeFormatter`: that formatter *can* take an explicit reference
    /// date instead of reading the live clock, which is why it looked like the right
    /// tool here, but for a same-day difference it renders "now," not "Today" — there
    /// turns out to be no Foundation API that turns an arbitrary reference date into
    /// "Today" the way `Calendar.isDateInToday` does for the real one. Weekday names
    /// and absolute dates go through `Date.FormatStyle`, which has no such gap.
    private static func title(for dayStart: Date, startOfNow: Date, calendar: Calendar) -> String {
        let locale = calendar.locale ?? .autoupdatingCurrent
        let daysBeforeNow = calendar.dateComponents([.day], from: dayStart, to: startOfNow).day ?? 0

        if daysBeforeNow == 0 {
            return String(localized: "Today", comment: "Meeting list section header for meetings recorded today.")
        }
        if daysBeforeNow == 1 {
            return String(
                localized: "Yesterday",
                comment: "Meeting list section header for meetings recorded yesterday."
            )
        }

        // `timeZone` is spelled out explicitly: `Date.FormatStyle`'s own default is
        // `.autoupdatingCurrent`, which isn't necessarily the timezone `calendar` was
        // given, and `dayStart` is that calendar's midnight — rendering it in a
        // different timezone can shift it onto the wrong calendar day.
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(dayStart, equalTo: startOfNow, toGranularity: .weekOfYear) {
            return dayStart.formatted(style.weekday(.wide))
        }

        // Matches the row subtitle's existing `.abbreviated` date style elsewhere in
        // the app, just with the injected calendar/locale/timezone instead of the
        // current ones.
        return dayStart.formatted(style.month(.abbreviated).day().year())
    }
}
