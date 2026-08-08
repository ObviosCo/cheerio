import Foundation
import FoundationModels

/// One action item, after owner resolution — the form the app persists, renders, and
/// hands to external consumers.
///
/// Deliberately distinct from ``ActionItemDraft``, which is what the model produces.
/// A draft's attribution is a guess; nothing may act on it until
/// ``ActionItem/resolved(from:ownerNames:)`` has checked it against the labels that
/// are actually the owner's.
public struct ActionItem: Codable, Sendable, Equatable {
    /// Whether an agent may carry an item out, or only track it.
    ///
    /// `@Generable` because the model's judgement is one of the two inputs to a
    /// disposition; the other is the owner check, which can only ever demote. One
    /// enum shared with ``ActionItemDraft`` keeps a single vocabulary from the
    /// generation schema through to the exported JSON, instead of two spellings and a
    /// mapping between them.
    @Generable
    public enum Disposition: String, Codable, Sendable {
        /// The owner committed to this themselves, so an agent may do it for them.
        case actionable
        /// Someone else committed, or nobody did. Track it, prepare for it, never do
        /// it — this covers "they owe us something" and "check in next time" alike.
        case followUp
    }

    public let text: String
    /// Who committed, when the transcript named someone. A display name, *not* a trust
    /// signal: nil here means nobody was named, not that the owner owns it.
    public let owner: String?
    /// Whether ``owner`` resolved to the meeting's owner — attribution metadata, not
    /// the execution decision. ``disposition`` alone says whether an agent may act:
    /// an owner-attributed item can still be `followUp` when the model saw a
    /// dependency the mechanical check can't. What `isOwner == false` *guarantees*
    /// is the other direction — a non-owner item is never `actionable`.
    public let isOwner: Bool
    public let disposition: Disposition

    /// Module-internal on purpose, and `let` throughout: production callers go
    /// through ``resolved(from:ownerNames:)``, so no client can mint or mutate its
    /// way into an impossible trust state like `isOwner: false, disposition:
    /// .actionable`. Tests reach it via `@testable`; decoding enforces the same
    /// invariant in `init(from:)`.
    init(text: String, owner: String? = nil, isOwner: Bool, disposition: Disposition) {
        self.text = text
        self.owner = owner
        self.isOwner = isOwner
        self.disposition = disposition
    }

    /// Decoding is a construction path like any other, so it carries the same
    /// invariant: JSON claiming `isOwner: false` with `actionable` — hand-edited,
    /// or from a future buggy writer — comes back demoted rather than trusted.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        let owner = try container.decodeIfPresent(String.self, forKey: .owner)
        let isOwner = try container.decode(Bool.self, forKey: .isOwner)
        let disposition = try container.decode(Disposition.self, forKey: .disposition)
        self.init(
            text: text,
            owner: owner,
            isOwner: isOwner,
            disposition: isOwner ? disposition : .followUp
        )
    }
}

/// One action item as the model returns it: attribution included, unverified.
///
/// Three fields, and no more, because each one is paid for in every chunk of a
/// map-reduce over a ~4k-token context. `disposition` earns its place by being the one
/// judgement the transcript can't settle mechanically — whether a commitment is
/// something to do or something to watch for.
@Generable
public struct ActionItemDraft: Sendable {
    @Guide(description: "What needs to be done, as one short sentence")
    public var task: String

    @Guide(description: "The speaker label of whoever committed to it, or 'Unassigned' if the transcript doesn't say")
    public var owner: String

    @Guide(description: "actionable only if the user themselves committed; followUp for anyone else, and for anything unattributed")
    public var disposition: ActionItem.Disposition

    public init(task: String, owner: String, disposition: ActionItem.Disposition) {
        self.task = task
        self.owner = owner
        self.disposition = disposition
    }
}

extension ActionItem {
    /// Vets the model's drafts and merges repeats — the only way an ``ActionItem``
    /// comes into existence, so no code path can route around the trust invariant.
    ///
    /// The invariant: **an item may only be `actionable` if the owner committed to it
    /// themselves.** Speaker identity is the trust signal — "I'll draft the proposal"
    /// from the owner is work an agent may take on, while the same sentence from a
    /// guest is theirs to do and ours to track. Everything else in this function
    /// exists to make that decision on evidence rather than on the model's word:
    ///
    /// - A draft naming a guest is demoted to ``Disposition/followUp``, keeping the
    ///   name so a caller knows who to chase.
    /// - A draft naming nobody is demoted too. Erring the other way — letting an
    ///   agent do work nobody claimed — is worse than the owner re-reading a
    ///   follow-up they could have delegated.
    /// - Demotion only. A draft the model marked `followUp` stays one even when the
    ///   owner committed: the model may have seen a dependency ("I'll send it once
    ///   Carter signs") that the owner check can't.
    ///
    /// - Parameter ownerNames: enrolled `isMe` speaker names — the labels the owner's
    ///   own lines carry in the transcript the drafts came from. Compared
    ///   case-insensitively, unlike ``Meeting/isOwnerAttributed(_:ownerNames:)``: a
    ///   speaker label is a string we minted and can match exactly, while this is free
    ///   text the model echoed back.
    public static func resolved(from drafts: [ActionItemDraft], ownerNames: Set<String>) -> [ActionItem] {
        var items: [ActionItem] = []
        // Normalized text to position in `items`, so a repeat folds into the item it
        // repeats rather than appending. First occurrence keeps its position, which is
        // what makes the merge deterministic across chunks.
        var seen: [String: Int] = [:]

        for draft in drafts {
            let text = draft.task.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank task is nothing a consumer can act on or read.
            guard !text.isEmpty else { continue }

            let (owner, isOwner) = resolveOwner(draft.owner, ownerNames: ownerNames)
            let item = ActionItem(
                text: text,
                owner: owner,
                isOwner: isOwner,
                disposition: isOwner ? draft.disposition : .followUp
            )

            let key = normalizedText(text)
            if let index = seen[key] {
                items[index] = items[index].merging(item)
            } else {
                seen[key] = items.count
                items.append(item)
            }
        }
        return items
    }

    /// Folds a second sighting of the same commitment — the map step reading it in two
    /// chunks, or the model restating it — into one item, conservatively: `actionable`
    /// only where both agreed the owner committed.
    ///
    /// The kept name follows the merged trust verdict. When the sightings disagree
    /// about who committed, the merge demotes to a follow-up — and a follow-up's name
    /// is who to *chase*, so a guest's name wins over the owner's: keeping "Jackson"
    /// on an item Jackson doesn't own would tell the user to chase themselves.
    func merging(_ other: ActionItem) -> ActionItem {
        let bothOwner = isOwner && other.isOwner
        let bothActionable = disposition == .actionable && other.disposition == .actionable

        // The name follows the merged verdict. A demoted item's name is who to
        // chase, so a guest's name wins over the owner's — but when the sightings
        // name two *different* guests, the attribution is disputed (or these are two
        // people's takes on one commitment), and exporting an arbitrary one of them
        // would send the user to chase the wrong person. Disputed means unnamed.
        let mine = isOwner ? nil : owner
        let theirs = other.isOwner ? nil : other.owner
        let nonOwnerName: String?
        switch (mine, theirs) {
        case (let a?, let b?) where a.lowercased() != b.lowercased(): nonOwnerName = nil
        case (let a, let b): nonOwnerName = a ?? b
        }

        return ActionItem(
            text: text,
            owner: bothOwner ? (owner ?? other.owner) : nonOwnerName,
            isOwner: bothOwner,
            disposition: bothOwner && bothActionable ? .actionable : .followUp
        )
    }

    /// Maps the model's free-text owner onto the identity behind it: the display name
    /// to show (nil when nobody was named) and whether it's the owner.
    ///
    /// The owner arrives under any of three spellings — the enrolled name diarization
    /// put on their lines, the `[Me]` fallback an undiarized mic line carries, or a
    /// first-person word the model reached for instead of a label. A word for the room
    /// as a whole ("the team", "we") names nobody: a group commitment is not the
    /// owner's to hand to an agent.
    private static func resolveOwner(_ raw: String, ownerNames: Set<String>) -> (name: String?, isOwner: Bool) {
        // The model decorates labels — "[Me]", "Carter:", "(me)" — and the decoration
        // is never part of the name.
        let name = raw.trimmingCharacters(in: decoration)
        let key = name.lowercased()

        // Sorted so two enrolled names differing only in case resolve the same way
        // every run, rather than however the set happens to iterate.
        if let enrolled = ownerNames.sorted().first(where: { $0.lowercased() == key }) {
            return (enrolled, true)
        }
        // First person is the owner whether or not anyone has enrolled: the transcript
        // labels their undiarized mic lines "[Me]", which is all this is echoing.
        if ownerFirstPerson.contains(key) { return (nil, true) }
        if name.isEmpty || nobody.contains(key) { return (nil, false) }
        return (name, false)
    }

    /// The dedupe key: case, spacing, and trailing punctuation are all things the model
    /// varies between chunks while meaning the same commitment.
    static func normalizedText(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .joined(separator: " ")
    }

    /// Re-checks this item's trust state against who the owner is *now* — the
    /// answer changes when a line gets relabelled or an enrollment's `isMe` flips,
    /// and an `actionable` item authorized by stale identity is exactly what the
    /// trust rule exists to prevent.
    ///
    /// Demote-only, like everything else here: an item whose named committer no
    /// longer resolves to the owner drops to `followUp`, but a correction in the
    /// other direction never *promotes* — the model's original judgement about a
    /// dependency is gone by now, so `actionable` can't be safely reconstructed.
    /// `meetingHasOwnerLines` — whether any transcript line still resolves to the
    /// owner — gates *every* item, named or not: if the corrections removed the
    /// meeting's last owner line, nothing in it is the owner's to act on, whatever
    /// name an item carries. Named items additionally require their committer to
    /// still resolve to the owner; unnamed (first-person) ones have only the
    /// meeting-level evidence to lean on.
    func reconciled(ownerNames: Set<String>, meetingHasOwnerLines: Bool) -> ActionItem {
        var stillOwner = isOwner && meetingHasOwnerLines
        if let owner {
            stillOwner = stillOwner && ownerNames.contains { $0.lowercased() == owner.lowercased() }
        }
        guard stillOwner != isOwner else { return self }
        return ActionItem(text: text, owner: owner, isOwner: false, disposition: .followUp)
    }

    private static let decoration = CharacterSet(charactersIn: " \t\n[](){}<>:;,.!?*\"'-")
    private static let ownerFirstPerson: Set<String> = ["me", "i", "my", "myself", "self", "user", "the user", "owner"]

    fileprivate static func reconcile(
        _ items: [ActionItem], ownerNames: Set<String>, meetingHasOwnerLines: Bool
    ) -> [ActionItem] {
        items.map { $0.reconciled(ownerNames: ownerNames, meetingHasOwnerLines: meetingHasOwnerLines) }
    }
    private static let nobody: Set<String> = [
        "unassigned", "unattributed", "unknown", "unspecified", "none", "no one", "noone", "nobody",
        "n/a", "na", "tbd", "them", "someone", "anyone",
        // Group commitments. "we" reads as including the owner, and does — but so does
        // everyone else in the room, and an agent can't tell which part was theirs.
        "we", "us", "our", "all", "everyone", "both", "team", "the team", "group", "the group", "the room",
    ]
}

extension Meeting {
    /// Whether any transcript line still resolves to the owner — the evidence
    /// ``ActionItem/reconciled(ownerNames:meetingHasOwnerLines:)`` uses for items
    /// that carry no name.
    private func hasOwnerLines(ownerNames: Set<String>) -> Bool {
        segments.contains { Meeting.isOwnerAttributed($0, ownerNames: ownerNames) }
    }

    /// The persisted action items, re-checked against current speaker identity —
    /// what ``MeetingExport`` serializes, so the machine-consumable path never
    /// authorizes an action off a label that has since been corrected.
    public func reconciledActionItems(ownerNames: Set<String>) -> [ActionItem] {
        ActionItem.reconcile(
            actionItems, ownerNames: ownerNames,
            meetingHasOwnerLines: hasOwnerLines(ownerNames: ownerNames))
    }

    /// Persists the reconciliation. Call after anything that changes who a line
    /// belongs to — relabelling a speaker, correcting a single line, or flipping an
    /// enrollment's `isMe` — so the stored items agree with what an export would
    /// say. Returns whether anything changed.
    ///
    /// The rendered Markdown in `enhancedNotes` is deliberately left alone: it's a
    /// human-readable record frozen at generation time, like the summary prose
    /// around it. The structured items are what agents are told to route on, and
    /// they're reconciled both here and at export.
    @discardableResult
    public func reconcileActionItems(ownerNames: Set<String>) -> Bool {
        let reconciled = reconciledActionItems(ownerNames: ownerNames)
        guard reconciled != actionItems else { return false }
        actionItems = reconciled
        return true
    }
}
