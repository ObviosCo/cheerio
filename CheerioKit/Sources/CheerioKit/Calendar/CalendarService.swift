import EventKit
import Foundation

/// A lightweight, Sendable snapshot of a calendar event.
public struct CalendarMeeting: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    /// The user isn't in this one: either they replied "no", or the organizer
    /// cancelled it. Two different facts, one consequence — never offer to record it
    /// (see ``MeetingSuggestionPlanner``). Kept as one flag rather than two because
    /// nothing else in the app needs to tell them apart, and defaulted so the
    /// existing call sites that don't care don't have to say so.
    public let isDeclined: Bool

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        isDeclined: Bool = false
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.isDeclined = isDeclined
    }

    /// True if the event is happening now or starts within `leadTime`.
    public func isStartingSoon(leadTime: TimeInterval = 120, now: Date = .now) -> Bool {
        !isAllDay && now >= startDate.addingTimeInterval(-leadTime) && now < endDate
    }
}

/// Read-only EventKit wrapper. Used to suggest recording when a meeting
/// starts and to link meetings to calendar events.
public actor CalendarService {
    /// Single-user app, single event store. Launch only refreshes the cached access
    /// status from whatever the user already decided (`refreshAccessStatus()`,
    /// which never prompts) — actually requesting access happens exclusively from
    /// something the user chose to do (see `requestAccess()`).
    public static let shared = CalendarService()

    private let store = EKEventStore()
    private var hasAccess = false

    public init() {}

    /// Requests full calendar access, prompting the system dialog if the user
    /// hasn't decided yet. Returns false if denied — the app works fine without
    /// it, just without meeting suggestions.
    ///
    /// Only call this from something the user chose to do (the onboarding
    /// walkthrough's calendar step, or reopening it from Settings). Calendar is
    /// explicitly optional and explained before it's requested — a call here from
    /// an unconditional launch-time task would prompt again moments after someone
    /// deliberately skipped it in the walkthrough.
    @discardableResult
    public func requestAccess() async -> Bool {
        do {
            hasAccess = try await store.requestFullAccessToEvents()
        } catch {
            hasAccess = false
        }
        return hasAccess
    }

    /// Refreshes the cached access flag from whatever the user already decided,
    /// without ever prompting. Safe to call on every launch: `authorizationStatus`
    /// is a plain read, unlike `requestFullAccessToEvents`, which shows the system
    /// dialog the first time it's ever called.
    @discardableResult
    public func refreshAccessStatus() -> Bool {
        hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        return hasAccess
    }

    /// Non-all-day events for the rest of today, sorted by start time.
    public func todaysMeetings(now: Date = .now) -> [CalendarMeeting] {
        guard hasAccess else { return [] }
        let calendar = Calendar.current
        let endOfDay = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        let predicate = store.predicateForEvents(
            withStart: calendar.startOfDay(for: now),
            end: endOfDay,
            calendars: nil
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map { event in
                CalendarMeeting(
                    id: event.eventIdentifier,
                    title: event.title ?? "Untitled",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    isDeclined: Self.isDeclined(event)
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Whether the user has effectively opted out of this event.
    ///
    /// `EKEvent.status` is the organizer's verdict on the event as a whole, while the
    /// user's own reply lives on the attendee entry flagged `isCurrentUser` — an
    /// event you declined stays `.confirmed`, so both have to be asked. An event with
    /// no attendees at all (a block you put on your own calendar for an in-person
    /// conversation) is not declined, which matters: those are exactly the meetings
    /// Cheerio's speaker separation is verified against, and filtering on "has
    /// attendees" would silence the suggestion precisely there.
    private static func isDeclined(_ event: EKEvent) -> Bool {
        if event.status == .canceled { return true }
        return event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    /// The event happening right now (or starting within 2 minutes), if any.
    public func currentMeeting(now: Date = .now) -> CalendarMeeting? {
        todaysMeetings(now: now).first { $0.isStartingSoon(now: now) }
    }
}
