import SwiftUI

/// The transcript-ready callback's one line of non-modal feedback (issue #26
/// rules out alerts), rendered off `TranscriptCallbackStatus.shared`. Shared by
/// Settings › Callback and the meeting detail view's per-trigger run (#137), so
/// a run started in either place reports in both — the status object is a
/// singleton for exactly this reason.
struct CallbackStatusLabel: View {
    /// Read directly from the singleton rather than copied into `@State`: it's
    /// already `@Observable`, and accessing `status.outcome` from `body` is what
    /// registers this view for updates when `TranscriptReadyRunner` changes it.
    private let status = TranscriptCallbackStatus.shared

    var body: some View {
        switch status.outcome {
        case .idle:
            EmptyView()
        case .running(let title):
            Label("Running for “\(title)”…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .succeeded(let title):
            Label("Finished for “\(title)”", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let title, let detail):
            // `.error`, not `.attention` — this is an actual failure of the command
            // run, not a warning to notice and move past.
            StatusLabel(.error, "Failed for “\(title)”: \(detail)")
                .lineLimit(2)
        }
    }
}
