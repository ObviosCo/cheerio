import CheerioKit
import SwiftUI

/// A meeting's speaking order in one slim strip: every transcript segment, in
/// chronological order, filled with the same colour its chip uses.
///
/// The one other place ``SpeakerSlot/color`` is allowed to paint something besides
/// a chip — see `Design/README.md`. It's allowed here for the same reason a chip
/// gets it: this bar *is* the visual element, not text sitting next to one, so the
/// "colour is never the only signal" rule doesn't bind it the way it binds a
/// transcript line or a row background. A speaker's name is still never coloured.
///
/// Positioned by absolute offset rather than concatenated widths because the two
/// capture channels can overlap in time — someone talking over someone else is
/// real and shouldn't make the bar overflow its own width.
public struct SpeakerTimelineBar: View {
    private let meeting: Meeting

    public init(meeting: Meeting) {
        self.meeting = meeting
    }

    public var body: some View {
        // Computed once, here, and threaded through as plain values: `spans` sorts
        // every segment in the meeting, so reaching for it again per-span inside the
        // loop below — once for width, once for offset — was an O(n²) resort of the
        // whole transcript on every render instead of one O(n log n) pass.
        let spans = meeting.speakerTimeline
        let totalDuration = spans.map(\.end).max() ?? 0
        if totalDuration > 0 {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SpeakerSlot.unresolved.color.opacity(0.2))
                        .accessibilityHidden(true)
                    ForEach(spans) { span in
                        Capsule()
                            .fill(color(for: span))
                            .frame(width: width(for: span, totalDuration: totalDuration, in: geometry.size.width))
                            .offset(x: geometry.size.width * CGFloat(span.start / totalDuration))
                            .accessibilityElement()
                            .accessibilityLabel(accessibilityLabel(for: span))
                            .help(span.label)
                    }
                }
                // The 1-point width floor below can push a span that ends exactly at
                // `totalDuration` a hair past the strip's own trailing edge; without
                // this the whole bar's rounded corners are decorative, not load-bearing.
                .clipShape(Capsule())
            }
            .frame(height: Theme.Layout.speakerTimelineHeight)
        }
    }

    private func width(for span: SpeakerTimelineSpan, totalDuration: TimeInterval, in totalWidth: CGFloat) -> CGFloat {
        // A span under a point wide is invisible, not just thin, and a chip's
        // one-line turn is common enough that "invisible" would be the norm
        // rather than the edge case.
        max(1, totalWidth * CGFloat((span.end - span.start) / totalDuration))
    }

    private func color(for span: SpeakerTimelineSpan) -> Color {
        (meeting.speakerSlotAssigner.assignments[span.speakerKey] ?? .unresolved).color
    }

    /// What VoiceOver says for one span — colour and a hover-only `.help` are no
    /// substitute for an actual accessible label, the same rule ``SpeakerChip``
    /// already follows for the identical reason.
    private func accessibilityLabel(for span: SpeakerTimelineSpan) -> String {
        let range = "\(AudioTimeFormatting.string(from: span.start)) to \(AudioTimeFormatting.string(from: span.end))"
        return "\(span.label), \(range)"
    }
}
