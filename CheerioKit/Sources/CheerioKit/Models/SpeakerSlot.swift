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
public struct SpeakerSlotAssigner: Codable, Sendable, Equatable {
    public private(set) var assignments: [String: SpeakerSlot] = [:]
    private var nextSlot = 1

    public init() {}

    /// - Parameter isYou: pins the speaker to the navy `.you` slot, outside rotation.
    @discardableResult
    public mutating func slot(for speakerID: String, isYou: Bool = false) -> SpeakerSlot {
        if isYou {
            assignments[speakerID] = .you
            return .you
        }
        if let existing = assignments[speakerID] { return existing }
        guard nextSlot <= SpeakerSlot.capacity else {
            assignments[speakerID] = .unresolved
            return .unresolved
        }
        let assigned = SpeakerSlot.slot(nextSlot)
        nextSlot += 1
        assignments[speakerID] = assigned
        return assigned
    }
}
