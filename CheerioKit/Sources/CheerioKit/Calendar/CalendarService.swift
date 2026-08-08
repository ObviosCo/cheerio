import EventKit
import Foundation

/// A lightweight, Sendable snapshot of a calendar event.
public struct CalendarMeeting: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool

    /// True if the event is happening now or starts within `leadTime`.
    public func isStartingSoon(leadTime: TimeInterval = 120, now: Date = .now) -> Bool {
        !isAllDay && now >= startDate.addingTimeInterval(-leadTime) && now < endDate
    }
}

/// Read-only EventKit wrapper. Used to suggest recording when a meeting
/// starts and to link meetings to calendar events.
public actor CalendarService {
    /// Single-user app, single event store — access is requested once at launch.
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
            .map {
                CalendarMeeting(
                    id: $0.eventIdentifier,
                    title: $0.title ?? "Untitled",
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isAllDay: $0.isAllDay
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }

    /// The event happening right now (or starting within 2 minutes), if any.
    public func currentMeeting(now: Date = .now) -> CalendarMeeting? {
        todaysMeetings(now: now).first { $0.isStartingSoon(now: now) }
    }
}
