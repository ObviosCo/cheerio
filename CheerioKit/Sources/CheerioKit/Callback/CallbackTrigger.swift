import Foundation

/// One named CLI agent invocation the transcript-ready callback can run (issue
/// #137): a name to pick it by, the command string, and whether it's the one
/// that fires automatically when a meeting finishes processing.
///
/// The list of these lives in `UserDefaults` as one JSON blob
/// (``TranscriptCallbackSettings/triggers``), not in SwiftData. That's a
/// deliberate call, not a default: triggers are machine configuration like the
/// scope and retention settings around them, not meeting data — the MCP helper
/// opens the store read-only and must never need a schema migration to keep
/// answering queries, `UserDefaultsMigration` already carries every preference
/// key across the bundle-identifier rename wholesale, and a Codable struct on a
/// `@Model` is exactly the composite-migration trap the 26.8.10 incident
/// documents. What crosses into SwiftData is only the per-meeting *choice* of
/// trigger (``ProcessingPlan/triggerID``), which is genuinely meeting state.
public struct CallbackTrigger: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var command: String
    public var isDefault: Bool

    public init(id: UUID = UUID(), name: String, command: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.isDefault = isDefault
    }

    /// The command as the runner should receive it, or `nil` when it's blank —
    /// the same "blank means off" reading `TranscriptCallbackSettings.command`
    /// has always had, because there's no command a person could type that means
    /// "do nothing" on purpose.
    public var trimmedCommand: String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What menus and pickers show for this trigger: the name, unless it's
    /// blank — a trigger mid-creation hasn't been named yet, and an empty menu
    /// row would be unclickable rather than merely unnamed.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled trigger" : trimmed
    }
}

extension [CallbackTrigger] {
    /// Restores the exactly-one-default invariant: a non-empty list has exactly
    /// one trigger marked default (the first marked one wins; none marked
    /// promotes the first), and an empty list stays empty. Every persisted list
    /// goes through this on write *and* read, so no UI has to handle a
    /// zero-default or two-default list.
    public func normalized() -> [CallbackTrigger] {
        guard !isEmpty else { return self }
        var seenDefault = false
        var result = map { trigger in
            var trigger = trigger
            if trigger.isDefault {
                if seenDefault {
                    trigger.isDefault = false
                } else {
                    seenDefault = true
                }
            }
            return trigger
        }
        if !seenDefault {
            result[0].isDefault = true
        }
        return result
    }

    /// The list with `id` as the sole default. Unknown ids change nothing —
    /// there's no reasonable trigger to promote on a stale click.
    public func settingDefault(_ id: UUID) -> [CallbackTrigger] {
        guard contains(where: { $0.id == id }) else { return normalized() }
        return map { trigger in
            var trigger = trigger
            trigger.isDefault = trigger.id == id
            return trigger
        }
    }

    /// The list without `id`, re-normalized — deleting the default hands the
    /// role to the first remaining trigger rather than leaving none.
    public func removing(_ id: UUID) -> [CallbackTrigger] {
        filter { $0.id != id }.normalized()
    }
}
