import CheerioKit
import SwiftUI

// MARK: - Slot colour

// `SpeakerSlot` and `SpeakerSlotAssigner` themselves live in CheerioKit
// (`Models/SpeakerSlot.swift`): `SpeakerSlotAssigner` is what gets persisted on
// `Meeting`, and CheerioKit stays free of SwiftUI so it can build for the MCP
// helper and for package tests with no UI at all. This extension is the one
// place the slot meets an actual `Color`, resolved from the asset catalog that
// only exists in this app target.
extension SpeakerSlot {
    public var color: Color {
        switch self {
        case .you:
            return Color("Speaker/Self", bundle: .main)
        case .slot(let n):
            let clamped = min(max(n, 1), Self.capacity)
            return Color("Speaker/Slot\(clamped)", bundle: .main)
        case .unresolved:
            return Color("Speaker/Unresolved", bundle: .main)
        }
    }

    /// The monogram foreground. One value per appearance clears 4.5:1 against
    /// every slot, so there is no per-slot foreground to get wrong.
    public var onChip: Color { Theme.Colors.speakerOnChip }
}

// MARK: - Provenance

/// How a speaker label got here — four rungs, read off the model, not invented.
///
/// The rule that makes this worth having: **certainty is unmarked. Only the
/// model's guesses carry a mark.** Fix a label and the mark goes away; that
/// disappearance is the receipt that corrections outrank the model.
public enum SpeakerProvenance: Hashable, Sendable {
    /// Pre-identification: the line is only known by its audio channel.
    case channelDefault
    /// The diarizer split a voice out but has no name for it — `Speaker 3`.
    case diarizerGenerated
    /// The model matched a voice to an enrolled name. Not checked yet.
    case modelMatched
    /// You said so. The clean resting state.
    case userSettled

    public init(isSpeakerLabelManual: Bool, isDiarizerGeneratedLabel: Bool, hasName: Bool) {
        if isSpeakerLabelManual {
            self = .userSettled
        } else if isDiarizerGeneratedLabel {
            self = .diarizerGenerated
        } else if hasName {
            self = .modelMatched
        } else {
            self = .channelDefault
        }
    }

    /// The hairline ring — the only mark in the system.
    var showsRing: Bool { self == .modelMatched }

    /// What the export writes, since Markdown has no hue, no chip and no ring.
    /// A settled name is written plainly; only uncertainty is stated in words.
    public var exportSuffix: String {
        switch self {
        case .userSettled: return ""
        case .modelMatched: return " (auto)"
        case .diarizerGenerated: return " (unidentified)"
        case .channelDefault: return " (unidentified)"
        }
    }
}

// MARK: - Speaker

public struct Speaker: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var slot: SpeakerSlot
    public var provenance: SpeakerProvenance

    public init(id: String, name: String, slot: SpeakerSlot, provenance: SpeakerProvenance) {
        self.id = id
        self.name = name
        self.slot = slot
        self.provenance = provenance
    }

    /// Letters carry identity; colour only reinforces it. The monogram has to
    /// survive greyscale, exported Markdown and VoiceOver on its own.
    public var monogram: String {
        switch provenance {
        case .diarizerGenerated, .channelDefault:
            // A voice with no name yet reads as its numeral, not as initials.
            return name.filter(\.isNumber).isEmpty ? "?" : String(name.filter(\.isNumber).suffix(2))
        case .modelMatched, .userSettled:
            let initials = name.split(separator: " ").compactMap(\.first).prefix(2)
            return initials.isEmpty ? "?" : String(initials).uppercased()
        }
    }
}
