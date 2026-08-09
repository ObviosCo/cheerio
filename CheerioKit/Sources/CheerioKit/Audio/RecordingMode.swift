import Foundation

/// Whether a recording is a video/voice call, where the mic can hear the speakers, or an
/// in-person/solo meeting, where there is no far-end signal for echo cancellation to remove.
///
/// This is the seam CLAUDE.md reserves for issue #12: it decides whether acoustic echo
/// cancellation runs, never whether either capture channel starts. Both the mic and the
/// system tap run in every mode — see `CaptureSession`.
///
/// Follows ``AudioRetention``'s pattern: the raw value is stored directly in `UserDefaults`
/// so the Settings UI can bind it with `@AppStorage`, and ``current`` gives non-view code the
/// same value without duplicating the key or the fallback.
public enum RecordingMode: Int, CaseIterable, Identifiable, Sendable {
    case inPerson = 0
    case videoCall = 1

    public static let defaultsKey = "recordingMode"
    /// In-person leaves capture exactly as it already ran and was verified (see CLAUDE.md's
    /// 2026-07-31 speaker-differentiation measurement). Video-call mode turns on echo
    /// cancellation, which issue #5's design comment flags as needing a live A/B against real
    /// speaker playback before it's trusted as the default — so it ships opt-in until that
    /// measurement (`Scripts/aec-ab-measure.sh`) has been run.
    public static let `default` = RecordingMode.inPerson

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .inPerson: "In Person"
        case .videoCall: "Video Call"
        }
    }

    /// Whether this mode should try to enable acoustic echo cancellation on the mic input.
    ///
    /// Off for in-person: AEC targets a specific far-end signal coming back out of the
    /// speakers, and in a room with no far end it can just as easily suppress the other people
    /// actually in the room — issue #5's design comment calls this out explicitly.
    public var echoCancellationEnabled: Bool {
        switch self {
        case .inPerson: false
        case .videoCall: true
        }
    }

    /// The setting as stored by the Settings UI's `@AppStorage`, for code that isn't a view.
    public static var current: RecordingMode {
        let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Int
        return stored.flatMap(RecordingMode.init(rawValue:)) ?? .default
    }
}
