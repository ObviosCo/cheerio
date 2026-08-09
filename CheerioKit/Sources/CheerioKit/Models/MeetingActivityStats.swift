import Foundation

/// The recent-activity numbers the empty-state dashboard shows (#124) — each one
/// answerable from meetings the caller already has loaded (a `@Query` result, in
/// practice), the same "no extra fetch" shape as ``MeetingListGrouping``.
public struct MeetingActivityStats: Equatable, Sendable {
    public let meetingsThisWeek: Int
    /// Minutes actually recorded this week, not minutes on a calendar — a meeting
    /// that ran short (or long) counts for what it actually was. A meeting still
    /// missing `endedAt` (the app quit mid-recording) contributes nothing rather than
    /// a guess at how long it would have run.
    public let minutesTranscribedThisWeek: Int
    /// Every persisted action item, across every meeting ever recorded, still
    /// sitting at ``ActionItem/Disposition/followUp`` — the ones nobody committed to
    /// and an agent may only track, never do. Not scoped to this week: a follow-up
    /// doesn't stop being open just because the meeting that raised it did.
    public let openFollowUps: Int

    public init(meetingsThisWeek: Int, minutesTranscribedThisWeek: Int, openFollowUps: Int) {
        self.meetingsThisWeek = meetingsThisWeek
        self.minutesTranscribedThisWeek = minutesTranscribedThisWeek
        self.openFollowUps = openFollowUps
    }

    /// - Parameters:
    ///   - now / calendar: injected rather than defaulted to `Date()`/`.current`, so
    ///     a test can pin "this week" the same way ``MeetingListGrouping`` pins
    ///     "today."
    public static func compute(
        from meetings: [Meeting], now: Date = .now, calendar: Calendar = .current
    ) -> MeetingActivityStats {
        let openFollowUps = meetings.reduce(0) { total, meeting in
            total + meeting.actionItems.filter { $0.disposition == .followUp }.count
        }
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else {
            // `dateInterval(of:for:)` only fails for a calendar with no concept of a
            // week — not a real case for `.current`, but nothing here should crash
            // over it. This week's meeting count and minutes just can't be answered,
            // so they come back zero; the follow-up count above doesn't depend on a
            // week boundary at all.
            return MeetingActivityStats(meetingsThisWeek: 0, minutesTranscribedThisWeek: 0, openFollowUps: openFollowUps)
        }

        let thisWeek = meetings.filter { week.contains($0.startedAt) }
        let seconds = thisWeek.reduce(0.0) { total, meeting in
            guard let endedAt = meeting.endedAt else { return total }
            return total + max(0, endedAt.timeIntervalSince(meeting.startedAt))
        }

        return MeetingActivityStats(
            meetingsThisWeek: thisWeek.count,
            minutesTranscribedThisWeek: Int((seconds / 60).rounded()),
            openFollowUps: openFollowUps
        )
    }
}
