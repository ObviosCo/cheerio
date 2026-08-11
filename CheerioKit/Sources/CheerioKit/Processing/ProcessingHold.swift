import Foundation

/// How long a stopped recording waits in the post-meeting holding state (issue
/// #136) before processing — note generation, then the transcript-ready callback —
/// starts on its own.
///
/// Following ``AudioRetention``'s pattern: the raw value (seconds) is stored
/// directly in `UserDefaults` so the Settings UI can bind it with `@AppStorage`,
/// and ``current`` gives non-view code the same value without duplicating the key
/// or the fallback.
public enum ProcessingHoldDuration: Int, CaseIterable, Identifiable, Sendable {
    /// No holding state at all — the moment a recording stops, processing runs,
    /// exactly as it did before the holding state existed. This is the zero-touch
    /// contract: `.off` must be indistinguishable from the app that shipped
    /// without #136.
    case off = 0
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case fifteenMinutes = 900

    public static let defaultsKey = "processingHoldSeconds"
    /// Two minutes of *idle* time, not two minutes total: every edit in the
    /// holding state pushes the deadline out (``ProcessingHoldWindow/recordActivity(at:)``),
    /// so someone actively typing notes is never cut off mid-thought, and someone
    /// who walked away only delays their notes by this much.
    public static let `default` = ProcessingHoldDuration.twoMinutes

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .off: "Off — process immediately"
        case .oneMinute: "1 minute"
        case .twoMinutes: "2 minutes"
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        }
    }

    /// The grace period as a time interval, or nil for ``off`` — nil rather than
    /// zero so no caller can accidentally build a window that expires instantly
    /// instead of skipping the hold outright.
    public var gracePeriod: TimeInterval? {
        self == .off ? nil : TimeInterval(rawValue)
    }

    /// The setting as stored by the Settings UI's `@AppStorage`, for code that
    /// isn't a view.
    public static var current: ProcessingHoldDuration {
        let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Int
        return stored.flatMap(ProcessingHoldDuration.init(rawValue:)) ?? .default
    }

    /// Whether a recording of this kind should enter the holding state at all.
    ///
    /// `.off` never holds — that's the zero-touch contract above. Directives never
    /// hold either, whatever this is set to: a directive is fire-and-forget by
    /// definition (you talked instructions at your agent; the recording *is* the
    /// input), so parking it behind a review window would defeat its one purpose.
    /// Issue #136 flags this asymmetry explicitly. A future kind holds by default
    /// — opting out is the exception a kind has to argue for, not the rule.
    public func applies(to kind: MeetingKind) -> Bool {
        self != .off && kind != .directive
    }
}

/// The grace-period arithmetic for one holding state: when it auto-processes, and
/// how activity pushes that moment out.
///
/// A value type with explicit dates, not a timer — the timer lives in
/// `CaptureSession` (app target), which sleeps until ``deadline`` and re-checks.
/// Keeping the arithmetic here is what makes it testable without waiting on a
/// clock.
public struct ProcessingHoldWindow: Sendable, Equatable {
    /// How long a quiet holding state lasts before processing starts on its own.
    public let gracePeriod: TimeInterval
    /// When processing starts unless something pushes it out again.
    public private(set) var deadline: Date

    /// - Parameter gracePeriod: must be positive — ``ProcessingHoldDuration/gracePeriod``
    ///   returns nil for `.off` precisely so no window is ever built for it.
    public init(startedAt: Date, gracePeriod: TimeInterval) {
        self.gracePeriod = gracePeriod
        self.deadline = startedAt.addingTimeInterval(gracePeriod)
    }

    /// The user did something in the holding UI — typed a character, flipped a
    /// control — so the countdown restarts from now: the grace period measures
    /// *idle* time, not total time, because cutting someone off mid-sentence to
    /// start processing is worse than waiting out another window.
    ///
    /// `max` so the deadline only ever moves later: a stale or backdated activity
    /// date (a clock adjustment, an event delivered out of order) must never pull
    /// an auto-process forward on someone still editing.
    public mutating func recordActivity(at date: Date) {
        deadline = max(deadline, date.addingTimeInterval(gracePeriod))
    }

    /// Seconds until the deadline, clamped at zero — for a countdown display,
    /// which should read "0" while processing kicks off, never a negative.
    public func remaining(at date: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(date))
    }

    public func isExpired(at date: Date) -> Bool {
        date >= deadline
    }
}
