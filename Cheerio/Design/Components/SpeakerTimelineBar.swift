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

    private var spans: [SpeakerTimelineSpan] { meeting.speakerTimeline }
    private var totalDuration: TimeInterval { spans.map(\.end).max() ?? 0 }

    public var body: some View {
        if totalDuration > 0 {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(SpeakerSlot.unresolved.color.opacity(0.2))
                    ForEach(spans) { span in
                        Capsule()
                            .fill(color(for: span))
                            .frame(width: width(for: span, in: geometry.size.width))
                            .offset(x: geometry.size.width * CGFloat(span.start / totalDuration))
                            .help(span.label)
                    }
                }
            }
            .frame(height: Theme.Layout.speakerTimelineHeight)
        }
    }

    private func width(for span: SpeakerTimelineSpan, in totalWidth: CGFloat) -> CGFloat {
        // A span under a point wide is invisible, not just thin, and a chip's
        // one-line turn is common enough that "invisible" would be the norm
        // rather than the edge case.
        max(1, totalWidth * CGFloat((span.end - span.start) / totalDuration))
    }

    private func color(for span: SpeakerTimelineSpan) -> Color {
        (meeting.speakerSlotAssigner.assignments[span.speakerKey] ?? .unresolved).color
    }
}
