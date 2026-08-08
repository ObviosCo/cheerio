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

    private init() {}

    func markRunning(title: String) {
        outcome = .running(title: title)
    }

    func markSucceeded(title: String) {
        outcome = .succeeded(title: title)
    }

    func markFailed(title: String, detail: String) {
        outcome = .failed(title: title, detail: detail)
    }
}
