import Foundation

/// A speaker's stable colour slot.
///
/// Slot order is **separation priority, not sequence**: two speakers get navy
/// and rose, the furthest apart under every form of colour vision deficiency,
/// and the harder hues only appear in meetings that are already hard.
///
/// Assign in numeric order as speakers resolve, then **store the slot on the
/// speaker, not on the render**. Re-running identification must not reshuffle
/// colours under someone who is mid-read.
///
/// The colour itself (`Speaker/Slot1`, etc.) lives in the app target's asset
/// catalog, not here — `CheerioKit` stays free of SwiftUI so it can persist
/// this alongside ``Meeting`` and still build for a context with no UI (the
/// MCP helper, package tests). `Cheerio/Design/SpeakerIdentity.swift` extends
/// this type with the `Color` those slots resolve to.
public enum SpeakerSlot: Hashable, Codable, Sendable {
    /// You. Navy, pinned, never enters rotation — you are not one of the categories.
    case you
    /// 1...8, in assignment order.
    case slot(Int)
    /// Heard, but identification hasn't run or didn't land.
    case unresolved

    public static let capacity = 8
}

/// Hands out slots in order and remembers them. Persist this with the
/// meeting (see ``Meeting/speakerSlotAssigner``) — the slot is part of the
/// speaker's identity, not a view detail.
///
/// Keyed by speaker identity (``SpeakerSummary/id``, or the equivalent
/// per-segment ``TranscriptSegment/speakerSlotKey``), which changes whenever a
/// label changes — a rename, a merge, an enrollment. That means a plain
/// "hand out the next number" counter isn't enough: a rename would look like
/// a brand-new speaker to ``slot(for:isYou:)``, visibly changing that
/// person's colour, while the *old* key it abandoned would stay counted
/// against capacity forever. ``rename(from:to:)`` and ``reconcile(liveIDs:)``
/// exist to keep both of those honest — see ``Meeting/relabelSpeaker(_:to:)``
/// and ``Meeting/resolveSpeakerSlots(ownerNames:)`` for where they're called.
public struct SpeakerSlotAssigner: Codable, Sendable, Equatable {
    public private(set) var assignments: [String: SpeakerSlot] = [:]

    public init() {}

    /// - Parameter isYou: pins the speaker to the navy `.you` slot, outside rotation.
    @discardableResult
    public mutating func slot(for speakerID: String, isYou: Bool = false) -> SpeakerSlot {
        if isYou {
            assignments[speakerID] = .you
            return .you
        }
        if let existing = assignments[speakerID] { return existing }
        guard let number = lowestUnusedSlotNumber() else {
            assignments[speakerID] = .unresolved
            return .unresolved
        }
        let assigned = SpeakerSlot.slot(number)
        assignments[speakerID] = assigned
        return assigned
    }

    /// Transfers an existing assignment to a new key when a speaker's label
    /// changes, so a rename or an enrollment can't look like a brand-new
    /// speaker to ``slot(for:isYou:)`` — the whole reason this type exists is
    /// so a correction never reshuffles a colour under someone mid-read.
    ///
    /// If `to` already holds a slot — merging into a speaker who was already
    /// separately identified — that slot wins and `from`'s assignment is
    /// simply dropped, which is what frees its number for reuse. If `from`
    /// never had a slot (nothing to transfer) or `from == to` (no rename
    /// actually happened), this is a no-op.
    public mutating func rename(from: String, to: String) {
        guard from != to else { return }
        guard let existing = assignments.removeValue(forKey: from) else { return }
        if assignments[to] == nil {
            assignments[to] = existing
        }
    }

    /// Drops any assignment whose key isn't in `liveIDs` — reclaims capacity
    /// from a speaker who no longer exists under that identity: merged away
    /// by ``rename(from:to:)``, or the meeting's last line under that label
    /// was corrected to someone else outside a whole-speaker rename. Safe to
    /// call on every resolution pass; a key still present is left untouched.
    public mutating func reconcile(liveIDs: Set<String>) {
        assignments = assignments.filter { liveIDs.contains($0.key) }
    }

    /// The lowest numbered slot (1...capacity) no live key currently holds —
    /// not a monotonic counter, so a number freed by ``reconcile(liveIDs:)``
    /// or a merge in ``rename(from:to:)`` is actually available again, rather
    /// than being retired the moment it's first handed out.
    private func lowestUnusedSlotNumber() -> Int? {
        let used = Set(
            assignments.values.compactMap { slot in
                if case .slot(let number) = slot { return number }
                return nil
            })
        for number in 1...SpeakerSlot.capacity where !used.contains(number) {
            return number
        }
        return nil
    }
}
