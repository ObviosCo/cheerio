import Foundation

/// One "this is starting — record it?" offer, and when it should land.
public struct MeetingSuggestion: Identifiable, Equatable, Sendable {
    /// The raw EventKit identifier. Shared across every occurrence of a recurring
    /// event, which makes it safe for exactly one purpose downstream: it's what's
    /// passed as `calendarEventID` when the suggestion is accepted, because a
    /// started recording links to the *event*, not to one particular occurrence of
    /// it. Never use this as a dedup or scheduling key — see ``occurrenceKey``.
    public let eventID: String
    /// What actually makes an offer unique: ``eventID`` folded together with this
    /// occurrence's own start date. `eventID` alone repeats across a recurring
    /// event's instances, so the raw identifier can't tell "today's standup" apart
    /// from "tomorrow's standup" — the dedup ledger and the notification request
    /// identifier both key on this instead, so two occurrences seen in the same
    /// planning pass get distinct requests, and a re-plan doesn't re-offer one
    /// that's already been queued.
    public let occurrenceKey: String
    public let title: String
    public let startDate: Date
    /// When the notification should be delivered — the event's start, or *now* for
    /// an event that started within the grace window while the app wasn't looking.
    public let fireDate: Date

    public var id: String { occurrenceKey }

    public init(eventID: String, title: String, startDate: Date, fireDate: Date) {
        self.eventID = eventID
        self.occurrenceKey = Self.occurrenceKey(eventID: eventID, startDate: startDate)
        self.title = title
        self.startDate = startDate
        self.fireDate = fireDate
    }

    /// Combines an event's identifier with one occurrence's start date into the key
    /// that names that specific occurrence. ISO-8601 rather than, say, a raw
    /// `TimeInterval`, because this ends up inside a `UNNotificationRequest`
    /// identifier and a `UserDefaults`-backed ledger entry — both places where
    /// "legible in a debugger or a defaults dump" is worth the extra characters.
    ///
    /// Builds its own `ISO8601DateFormatter` on every call rather than sharing one
    /// off a `static let`: the class isn't `Sendable`, and this isn't called often
    /// enough for the allocation to be worth a concurrency-safety workaround.
    public static func occurrenceKey(eventID: String, startDate: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(eventID)#\(formatter.string(from: startDate))"
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
        /// The calendar event the in-flight (or just-finished) recording is linked
        /// to, if any. Kept around for `NotificationService` to withdraw that
        /// event's already-pending notification requests — never compare this
        /// directly against a candidate meeting's id for the dedup veto below; see
        /// ``occurrenceKey``.
        public let eventID: String?
        /// Identifies the *specific occurrence* of ``eventID`` the recording is or
        /// was tied to — see
        /// ``MeetingSuggestion/occurrenceKey(eventID:startDate:)``. `eventID` alone
        /// can't stand in for this: it repeats across every occurrence of a
        /// recurring event, so comparing it directly would suppress every later
        /// occurrence of that event for as long as this context persists (in
        /// practice, until the *next* recording finishes and replaces
        /// `lastFinishedMeeting`) — recording today's standup would otherwise keep
        /// tomorrow's off the offer list too. Nil whenever `eventID` is, or when the
        /// occurrence's start date wasn't available when the recording began; either
        /// way, that withholds the veto rather than risking one broader than the
        /// single occurrence actually recorded.
        public let occurrenceKey: String?

        public static let idle = RecordingContext(isRecording: false, eventID: nil, occurrenceStart: nil)

        public static func recording(eventID: String?, occurrenceStart: Date? = nil) -> RecordingContext {
            RecordingContext(isRecording: true, eventID: eventID, occurrenceStart: occurrenceStart)
        }

        public init(isRecording: Bool, eventID: String?, occurrenceStart: Date? = nil) {
            self.isRecording = isRecording
            self.eventID = eventID
            self.occurrenceKey = eventID.flatMap { id in
                occurrenceStart.map { MeetingSuggestion.occurrenceKey(eventID: id, startDate: $0) }
            }
        }
    }

    /// The events worth offering to record, soonest first.
    ///
    /// An event qualifies when all of these hold:
    /// - Nothing is being recorded. Cheerio records one meeting at a time, so an
    ///   offer to start a second one is an offer it couldn't honour — and, once
    ///   idle again, the *occurrence* just recorded least of all
    ///   (``RecordingContext/occurrenceKey``). Scoped to that one occurrence rather
    ///   than the event as a whole, so recording today's standup doesn't suppress
    ///   tomorrow's.
    /// - It isn't all-day. `CalendarService.todaysMeetings` filters these out too;
    ///   the check is repeated here so the rule survives being handed a list from
    ///   somewhere else, and so it's visible in one place with the others.
    /// - The user hasn't declined it and the organizer hasn't cancelled it.
    /// - It hasn't already ended, and it isn't a zero-length marker (a reminder or
    ///   an all-day-ish placeholder someone entered as a point in time).
    /// - It starts within ``lookahead``, or started no more than ``grace`` ago.
    /// - It hasn't been offered before. Once per *occurrence*, ever — declining an
    ///   offer by ignoring it is still an answer, and asking twice about one meeting
    ///   is the fastest way to make someone turn the whole feature off. A recurring
    ///   event's `EKEvent.eventIdentifier` repeats across every occurrence, so what's
    ///   actually checked is `meeting.id` folded together with that occurrence's own
    ///   start date — see ``MeetingSuggestion/occurrenceKey(eventID:startDate:)``.
    ///   `alreadyNotified` holds those occurrence keys, not raw event identifiers.
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
                let occurrenceKey = MeetingSuggestion.occurrenceKey(
                    eventID: meeting.id, startDate: meeting.startDate)
                guard !alreadyNotified.contains(occurrenceKey) else { return false }
                guard occurrenceKey != recording.occurrenceKey else { return false }
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

    /// The pure diff between what's currently pending with the system and what's
    /// currently a candidate, both keyed by occurrence — the shape reconciliation
    /// actually needs.
    ///
    /// `NotificationService` is the only caller, and the only thing it does with the
    /// result is turn `toRemove` into a `removePendingNotificationRequests` call and
    /// `toAdd` into a batch of `schedule` calls — no `UNUserNotificationCenter`
    /// dependency belongs in the decision itself, so it's kept here, next to
    /// ``suggestions(for:now:alreadyNotified:recording:)``, where it can be tested
    /// directly.
    ///
    /// `pending` minus `candidates` is what to withdraw: an occurrence that was
    /// offered but no longer qualifies, because the event was cancelled, deleted,
    /// moved to a different start (which is a different occurrence key entirely —
    /// see ``MeetingSuggestion/occurrenceKey``), or declined since the offer went
    /// out. `candidates` minus `pending` is what's newly worth offering. An empty
    /// `candidates` set — the suggestion toggle just went off, or a recording just
    /// started — reduces to "withdraw everything pending," which is exactly the
    /// cleanup both of those cases need; nothing bespoke required.
    ///
    /// Deliberately takes and returns bare occurrence keys rather than
    /// `MeetingSuggestion`s or `UNNotificationRequest`s: the caller holds the
    /// mapping from key back to whichever richer value it needs on each side
    /// (already-pending identifiers on the remove side, full suggestions with a
    /// title and dates on the add side), and duplicating that mapping in here would
    /// just be a second place for it to drift from the caller's.
    public static func reconcile(
        pending: Set<String>, candidates: Set<String>
    ) -> (toRemove: Set<String>, toAdd: Set<String>) {
        (pending.subtracting(candidates), candidates.subtracting(pending))
    }
}

/// Which occurrences have already been offered, so none is ever offered twice.
///
/// Keyed by occurrence key (``MeetingSuggestion/occurrenceKey(eventID:startDate:)``),
/// not the raw EventKit identifier — that repeats across every occurrence of a
/// recurring event, so keying on it directly would suppress every occurrence after
/// the first one ever offered. Timestamped rather than a bare set of keys, so it can
/// be pruned: a set that only grows would still accumulate one entry per occurrence
/// forever. Pruning by age also handles the one case where re-offering is right — an
/// event whose identifier repeats tomorrow, at a different start date, produces a
/// genuinely different key.
public struct SuggestionLedger: Equatable, Sendable {
    public static let defaultsKey = "meetingSuggestionLedger"
    /// How long an entry suppresses re-offering. A day, because that's the span over
    /// which "this occurrence" means one meeting.
    public static let retention: TimeInterval = 24 * 60 * 60

    private var entries: [String: Date]

    public init(entries: [String: Date] = [:]) {
        self.entries = entries
    }

    public var occurrenceKeys: Set<String> { Set(entries.keys) }

    public func contains(_ occurrenceKey: String) -> Bool { entries[occurrenceKey] != nil }

    public mutating func record(_ occurrenceKey: String, at date: Date) {
        entries[occurrenceKey] = date
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
