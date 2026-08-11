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

/// The user-configured "transcript ready" triggers and whether one should run
/// for a given meeting, per issues #26 and #137.
///
/// This only decides *whether* to fire and *what* the command string is — the
/// process-running side (`Process` isn't portable) lives in the app target as
/// `TranscriptReadyRunner`.
public enum TranscriptCallbackSettings {
    /// Pre-#137 storage: one global command string. Still written (see
    /// ``triggers``'s setter) so a downgrade to a single-command build keeps the
    /// default trigger working, and still read as the migration source when no
    /// trigger list has ever been saved.
    public static let commandDefaultsKey = "transcriptCallbackCommand"
    /// Where the trigger list lives: one JSON blob in `UserDefaults` — see
    /// ``CallbackTrigger`` for why it's not SwiftData.
    public static let triggersDefaultsKey = "transcriptCallbackTriggers"

    /// The identity of the trigger synthesized from a pre-#137
    /// `transcriptCallbackCommand`. A fixed constant, not a fresh `UUID()` per
    /// read, because the migration below happens at *read* time and only persists
    /// on the first edit — a hold could stash this id in its ``ProcessingPlan``
    /// and processing must resolve it to the same trigger minutes later.
    public static let migratedTriggerID = UUID(uuidString: "3B6E4A1C-9D2F-4E8B-A7C5-0F1D8E6B2A94")!

    /// Every configured trigger, exactly one of them default when any exist.
    ///
    /// Reading migrates: a machine with only the legacy single command comes back
    /// as one trigger — named "Default", marked default, same command — so
    /// nobody's configured callback disappears on upgrade. The synthesis is pure
    /// (nothing is written until the user edits triggers in Settings), which is
    /// what keeps this getter safe to call from anywhere, tests included; the
    /// fixed ``migratedTriggerID`` is what makes repeated reads agree anyway.
    public static var triggers: [CallbackTrigger] {
        get {
            if let data = UserDefaults.standard.data(forKey: triggersDefaultsKey),
                let decoded = try? JSONDecoder().decode([CallbackTrigger].self, from: data)
            {
                return decoded.normalized()
            }
            guard let legacy = legacyCommand else { return [] }
            return [CallbackTrigger(id: migratedTriggerID, name: "Default", command: legacy, isDefault: true)]
        }
        set {
            let normalized = newValue.normalized()
            if let data = try? JSONEncoder().encode(normalized) {
                UserDefaults.standard.set(data, forKey: triggersDefaultsKey)
            }
            // Mirror the default's command into the legacy key (or clear it),
            // so a downgraded build reads the same automatic command this one
            // would run — the mirror is one line here and a restored callback
            // there.
            if let command = normalized.first(where: \.isDefault)?.trimmedCommand {
                UserDefaults.standard.set(command, forKey: commandDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: commandDefaultsKey)
            }
        }
    }

    private static var legacyCommand: String? {
        let stored = UserDefaults.standard.string(forKey: commandDefaultsKey) ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The trigger that fires automatically, when one exists — ``triggers``
    /// guarantees at most one carries the mark.
    public static var defaultTrigger: CallbackTrigger? {
        triggers.first(where: \.isDefault)
    }

    /// The automatic (default trigger's) command, or `nil` if none is configured
    /// or it's blank.
    ///
    /// Off by default: there's no way to type a command that means "do nothing"
    /// on purpose, so blank has to be read as disabled rather than as a command
    /// to actually run.
    public static var command: String? {
        defaultTrigger?.trimmedCommand
    }

    /// Whether any configured trigger could actually run — what UI offering a
    /// trigger choice should gate on, since a choice exists as soon as *some*
    /// trigger has a command, not only when the default does.
    public static var hasRunnableTrigger: Bool {
        triggers.contains { $0.trimmedCommand != nil }
    }

    /// The trigger with this id *as currently configured*, or nil if it has been
    /// deleted. This is the resolution for user-initiated runs — a click on a
    /// trigger by name — where falling back to the default would silently run a
    /// different command than the one clicked. Call it at decision time, never
    /// on a `CallbackTrigger` value captured earlier: any UI listing triggers
    /// can be minutes stale against a Settings window editing them, and the
    /// command that runs must be the one configured *now*, not the one rendered
    /// then.
    public static func trigger(withID id: UUID) -> CallbackTrigger? {
        triggers.first { $0.id == id }
    }

    /// The trigger `plan` asks for, falling back to the default.
    ///
    /// A plan naming a trigger that has since been *deleted* resolves to the
    /// default rather than to nothing: the user's "run the callback" decision
    /// survives losing the specific choice. A plan naming a trigger that still
    /// exists gets exactly that trigger, even if its command is blank — silently
    /// running a *different* command than the one chosen would be worse than not
    /// firing, so the blank-command gate in ``shouldFire(for:plan:)`` handles
    /// that case instead.
    public static func trigger(for plan: ProcessingPlan?) -> CallbackTrigger? {
        let triggers = self.triggers
        if let id = plan?.triggerID, let chosen = triggers.first(where: { $0.id == id }) {
            return chosen
        }
        return triggers.first(where: \.isDefault)
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
    /// either way — the *resolved* trigger's command (see ``trigger(for:)``), so
    /// the gate tests exactly the command that would run: a per-meeting "yes"
    /// can't run a command nobody configured.
    public static func shouldFire(for kind: MeetingKind, plan: ProcessingPlan?) -> Bool {
        guard trigger(for: plan)?.trimmedCommand != nil else { return false }
        guard let plan else { return TranscriptCallbackScope.current.includes(kind) }
        return plan.runCallback
    }
}
