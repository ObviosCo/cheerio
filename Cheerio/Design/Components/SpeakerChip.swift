import CheerioKit
import SwiftUI

/// The monogram chip: one object carrying identity, provenance and certainty.
///
/// Four states, each redundantly coded so none of them depends on hue alone:
///
/// | State              | Chip                     | Label              |
/// | ---                | ---                      | ---                |
/// | `.userSettled`     | filled, no ring          | primary, semibold  |
/// | `.modelMatched`    | filled, hairline ring    | secondary, regular |
/// | `.diarizerGenerated`| dashed, hollow, numeral | tertiary, italic   |
/// | `.channelDefault`  | grey filled              | tertiary, regular  |
public struct SpeakerChip: View {
    private let speaker: Speaker
    private let diameter: CGFloat

    public init(_ speaker: Speaker, diameter: CGFloat = Theme.Layout.chipDiameter) {
        self.speaker = speaker
        self.diameter = diameter
    }

    private var isHollow: Bool {
        speaker.provenance == .diarizerGenerated
    }

    private var fill: Color {
        switch speaker.provenance {
        case .diarizerGenerated: return .clear
        case .channelDefault: return SpeakerSlot.unresolved.color
        case .modelMatched, .userSettled: return speaker.slot.color
        }
    }

    public var body: some View {
        Text(speaker.monogram)
            .font(.system(size: diameter * 0.41, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(isHollow ? speaker.slot.color : speaker.slot.onChip)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(fill))
            .overlay {
                if isHollow {
                    Circle().strokeBorder(
                        speaker.slot.color,
                        style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.5])
                    )
                }
            }
            .overlay {
                if speaker.provenance.showsRing {
                    Circle()
                        .strokeBorder(speaker.slot.color, lineWidth: 1)
                        .opacity(0.55)
                        .padding(Theme.Layout.chipRingInset)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch speaker.provenance {
        case .userSettled: return speaker.name
        case .modelMatched: return "\(speaker.name), assigned automatically, not checked"
        case .diarizerGenerated, .channelDefault: return "\(speaker.name), not identified"
        }
    }
}

/// Chip plus name, as it sits in the transcript's speaker rail.
public struct SpeakerRailLabel: View {
    private let speaker: Speaker

    public init(_ speaker: Speaker) { self.speaker = speaker }

    public var body: some View {
        HStack(spacing: Theme.Space.x2) {
            Text(speaker.name)
                .chText(.speakerLabel)
                .fontWeight(speaker.provenance == .userSettled ? .semibold : .regular)
                .italic(speaker.provenance == .diarizerGenerated)
                .foregroundStyle(nameColor)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            SpeakerChip(speaker)
        }
        // A minimum, not a fixed width — the rail has to grow with Dynamic Type.
        .frame(
            minWidth: Theme.Layout.speakerRailMinWidth,
            idealWidth: Theme.Layout.speakerRailMinWidth,
            maxWidth: Theme.Layout.speakerRailMaxWidth,
            alignment: .trailing
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var nameColor: Color {
        switch speaker.provenance {
        case .userSettled: return Theme.Colors.textPrimary
        case .modelMatched: return Theme.Colors.textSecondary
        case .diarizerGenerated, .channelDefault: return Theme.Colors.textTertiary
        }
    }
}
