import Foundation

/// Non-modal feedback for the transcript-ready callback (issue #26 explicitly
/// rules out alerts: "surface failures non-modally"). Settings reads this to
/// show a subtle status line instead.
///
/// A singleton because the callback can fire from two unrelated places — the end
/// of a real recording in `CaptureSession`, possibly with Settings closed, and
/// the "Run now on last meeting" test button — and both need to land somewhere a
/// later-opened Settings window can still read.
@MainActor
@Observable
final class TranscriptCallbackStatus {
    static let shared = TranscriptCallbackStatus()

    enum Outcome: Equatable {
        case idle
        case running(title: String)
        case succeeded(title: String)
        case failed(title: String, detail: String)
    }

    private(set) var outcome: Outcome = .idle

    /// Which run ``outcome`` currently belongs to. Invocations are detached and can
    /// overlap — a real recording's callback and a "run now" test, or two test runs
    /// in a row — so without this an older, slower run finishing late would report
    /// its result over a newer run's, hiding a failure or replacing "running…" with
    /// a stale "finished". Last started run wins: `markRunning` claims the status
    /// line, and every other run's result is dropped rather than displayed out of
    /// order. That's the right semantic for one line of feedback — the user is
    /// watching the run they just started, and the log keeps the rest.
    private var currentRunID: UUID?

    private init() {}

    func markRunning(runID: UUID, title: String) {
        currentRunID = runID
        outcome = .running(title: title)
    }

    func markSucceeded(runID: UUID, title: String) {
        guard runID == currentRunID else { return }
        outcome = .succeeded(title: title)
    }

    func markFailed(runID: UUID, title: String, detail: String) {
        guard runID == currentRunID else { return }
        outcome = .failed(title: title, detail: detail)
    }
}
