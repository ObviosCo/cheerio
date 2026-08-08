import Foundation

/// One "this is starting — record it?" offer, and when it should land.
public struct MeetingSuggestion: Identifiable, Equatable, Sendable {
    /// The EventKit identifier, which is also what makes the offer unique: one
    /// suggestion per event, ever.
    public let eventID: String
    public let title: String
    public let startDate: Date
    /// When the notification should be delivered — the event's start, or *now* for
    /// an event that started within the grace window while the app wasn't looking.
    public let fireDate: Date

    public var id: String { eventID }

    public init(eventID: String, title: String, startDate: Date, fireDate: Date) {
        self.eventID = eventID
        self.title = title
        self.startDate = startDate
        self.fireDate = fireDate
    }
}

/// Decides which of today's calendar events deserve a "record it?" notification,
/// and when.
///
/// Pure and portable on purpose: this is the half of issue #51 that has an opinion
/// worth testing, and it holds no reference to `UNUserNotificationCenter`,
/// `EventKit`, or the recording pipeline. The app target's `NotificationService`
/// turns each suggestion into a scheduled `UNNotificationRequest`; everything about
/// *which* events qualify is decided here.
public enum MeetingSuggestionPlanner {
    /// How far ahead a suggestion is queued with the system.
    ///
    /// Deliberately short rather than "the rest of today". Two reasons: the system's
    /// pending-request budget is finite and shared with anything else the app ever
    /// schedules, and — more importantly — the notification authorization prompt is
    /// requested lazily, at the first moment something is actually scheduled. A short
    /// horizon means that prompt lands next to a meeting the user can see on their
    /// calendar, instead of at 8am because there's a 4pm standup.
    public static let lookahead: TimeInterval = 30 * 60

    /// How late an event may already have started and still be worth offering.
    ///
    /// Covers the app being launched, woken, or re-enabled a few minutes into
    /// something. Past this the offer stops being timely and starts being noise:
    /// "starting now" about a meeting that began twenty minutes ago is just wrong,
    /// and recording it under that title files a partial meeting as a whole one.
    public static let grace: TimeInterval = 5 * 60

    /// What the recorder is doing, which is a veto rather than a filter.
    public struct RecordingContext: Equatable, Sendable {
        public let isRecording: Bool
        /// The calendar event the in-flight recording is linked to, if any.
        public let eventID: String?

        public static let idle = RecordingContext(isRecording: false, eventID: nil)

        public static func recording(eventID: String?) -> RecordingContext {
            RecordingContext(isRecording: true, eventID: eventID)
        }

        public init(isRecording: Bool, eventID: String?) {
            self.isRecording = isRecording
            self.eventID = eventID
        }
    }

    /// The events worth offering to record, soonest first.
    ///
    /// An event qualifies when all of these hold:
    /// - Nothing is being recorded. Cheerio records one meeting at a time, so an
    ///   offer to start a second one is an offer it couldn't honour — and the event
    ///   the user is *already* recording least of all.
    /// - It isn't all-day. `CalendarService.todaysMeetings` filters these out too;
    ///   the check is repeated here so the rule survives being handed a list from
    ///   somewhere else, and so it's visible in one place with the others.
    /// - The user hasn't declined it and the organizer hasn't cancelled it.
    /// - It hasn't already ended, and it isn't a zero-length marker (a reminder or
    ///   an all-day-ish placeholder someone entered as a point in time).
    /// - It starts within ``lookahead``, or started no more than ``grace`` ago.
    /// - It hasn't been offered before. Once per event, ever — declining an offer by
    ///   ignoring it is still an answer, and asking twice about one meeting is the
    ///   fastest way to make someone turn the whole feature off.
    public static func suggestions(
        for meetings: [CalendarMeeting],
        now: Date = .now,
        alreadyNotified: Set<String>,
        recording: RecordingContext = .idle
    ) -> [MeetingSuggestion] {
        guard !recording.isRecording else { return [] }
        return
            meetings
            .filter { meeting in
                guard !meeting.isAllDay, !meeting.isDeclined else { return false }
                guard !alreadyNotified.contains(meeting.id) else { return false }
                guard meeting.id != recording.eventID else { return false }
                guard meeting.endDate > meeting.startDate else { return false }
                guard meeting.endDate > now else { return false }
                guard meeting.startDate <= now.addingTimeInterval(lookahead) else { return false }
                return meeting.startDate >= now.addingTimeInterval(-grace)
            }
            .sorted { $0.startDate < $1.startDate }
            .map {
                MeetingSuggestion(
                    eventID: $0.id,
                    title: $0.title,
                    startDate: $0.startDate,
                    // An event already under way fires immediately; one still to come
                    // fires at its start, which is what lets the system deliver it
                    // without the app watching a clock.
                    fireDate: max($0.startDate, now)
                )
            }
    }
}

/// Which events have already been offered, so none is ever offered twice.
///
/// Timestamped rather than a bare set of identifiers, so it can be pruned: EventKit
/// identifiers are stable and a set that only grows would accumulate every recurring
/// meeting's occurrences forever. Pruning by age also handles the one case where
/// re-offering is right — a recurring event whose identifier repeats tomorrow is a
/// genuinely different meeting.
public struct SuggestionLedger: Equatable, Sendable {
    public static let defaultsKey = "meetingSuggestionLedger"
    /// How long an entry suppresses re-offering. A day, because that's the span over
    /// which "this event" means one meeting.
    public static let retention: TimeInterval = 24 * 60 * 60

    private var entries: [String: Date]

    public init(entries: [String: Date] = [:]) {
        self.entries = entries
    }

    public var eventIDs: Set<String> { Set(entries.keys) }

    public func contains(_ eventID: String) -> Bool { entries[eventID] != nil }

    public mutating func record(_ eventID: String, at date: Date) {
        entries[eventID] = date
    }

    public mutating func prune(now: Date, retention: TimeInterval = SuggestionLedger.retention) {
        let cutoff = now.addingTimeInterval(-retention)
        entries = entries.filter { $0.value > cutoff }
    }

    /// Stored as seconds-since-reference-date rather than `Date`, because a
    /// `UserDefaults` value has to be a property-list type and a bare `Date` in a
    /// dictionary round-trips through `NSKeyedArchiver` in ways worth not depending
    /// on for a cache this disposable.
    public static func load(from defaults: UserDefaults = .standard) -> SuggestionLedger {
        let stored = defaults.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        return SuggestionLedger(entries: stored.mapValues { Date(timeIntervalSinceReferenceDate: $0) })
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(entries.mapValues(\.timeIntervalSinceReferenceDate), forKey: SuggestionLedger.defaultsKey)
    }
}
