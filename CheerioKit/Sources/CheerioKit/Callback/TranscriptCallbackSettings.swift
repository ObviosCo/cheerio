import Foundation

/// Which recordings the transcript-ready callback fires for.
///
/// Following ``AudioRetention``'s pattern: the raw value is stored directly in
/// `UserDefaults` so the Settings UI can bind it with `@AppStorage`, and
/// ``current`` gives non-view code the same value without duplicating the key or
/// the fallback.
public enum TranscriptCallbackScope: Int, CaseIterable, Identifiable, Sendable {
    case allRecordings = 0
    case directivesOnly = 1

    public static let defaultsKey = "transcriptCallbackScope"
    /// Every recording, not just directives — the narrower scope is the opt-in.
    public static let `default` = TranscriptCallbackScope.allRecordings

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .allRecordings: "All recordings"
        case .directivesOnly: "Directives only"
        }
    }

    public static var current: TranscriptCallbackScope {
        let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Int
        return stored.flatMap(TranscriptCallbackScope.init(rawValue:)) ?? .default
    }

    /// Whether a meeting of this kind falls inside this scope.
    public func includes(_ kind: MeetingKind) -> Bool {
        switch self {
        case .allRecordings: true
        case .directivesOnly: kind == .directive
        }
    }
}

/// The user-configured "transcript ready" command and whether it should run for a
/// given meeting, per issue #26.
///
/// This only decides *whether* to fire and *what* the command string is — the
/// process-running side (`Process` isn't portable) lives in the app target as
/// `TranscriptReadyRunner`.
public enum TranscriptCallbackSettings {
    public static let commandDefaultsKey = "transcriptCallbackCommand"

    /// The configured command, or `nil` if it's unset or blank.
    ///
    /// Off by default: the `@AppStorage` default for a string is `""`, and there's
    /// no way to type a command that means "do nothing" on purpose, so blank has to
    /// be read as disabled rather than as a command to actually run.
    public static var command: String? {
        let stored = UserDefaults.standard.string(forKey: commandDefaultsKey) ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the callback should fire for a meeting of this kind, under the
    /// current settings.
    ///
    /// This is purely "has the user asked for this" — *when* during a meeting's
    /// lifecycle it's safe to check this is `CaptureSession`'s call, documented
    /// where it fires.
    public static func shouldFire(for kind: MeetingKind) -> Bool {
        command != nil && TranscriptCallbackScope.current.includes(kind)
    }

    /// The same question with a per-meeting decision in hand: a ``ProcessingPlan``
    /// exists only for meetings that went through the post-meeting holding state
    /// (issue #136), and there the user saw and owned the toggle, so their answer
    /// replaces the global scope outright — in both directions. A nil plan is the
    /// zero-touch path (holding off, or a directive), which keeps deferring to the
    /// scope exactly as ``shouldFire(for:)`` always has. The command still gates
    /// either way: a per-meeting "yes" can't run a command nobody configured.
    public static func shouldFire(for kind: MeetingKind, plan: ProcessingPlan?) -> Bool {
        guard command != nil else { return false }
        guard let plan else { return TranscriptCallbackScope.current.includes(kind) }
        return plan.runCallback
    }
}
