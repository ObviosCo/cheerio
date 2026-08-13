import SwiftUI

/// "Something is running over this meeting right now", with the phase said in
/// words (issue #173).
///
/// The one place the app draws a busy indicator, for the same reason
/// `RecordingIndicator` is the one place it draws a recording ring: the sidebar
/// row, the meeting detail view and the live view all show this fact, and three
/// hand-rolled spinners would drift. There is no initialiser without a label —
/// motion alone answers "is it doing anything" but never "what", and the label
/// is also what VoiceOver and a greyscale screen have to go on.
///
/// The spinner is the system's own indeterminate `ProgressView`, deliberately:
/// it inherits whatever macOS does for appearance and for the accessibility
/// settings that govern motion, which a shape animated here would have to
/// re-implement and get wrong. The text is ``Theme/Colors/textSecondary``,
/// which clears AA on the page and on a selected row's fill in both
/// appearances — the two backgrounds this actually renders against.
public struct ProcessingIndicator: View {
    /// How much room the surface has. `row` is the library sidebar's two-line
    /// row, where this replaces the participants line; `section` is a header or
    /// a control group with body text around it.
    public enum Prominence {
        case row
        case section

        var controlSize: ControlSize {
            switch self {
            case .row: .mini
            case .section: .small
            }
        }

        var font: Font {
            switch self {
            case .row: .caption
            case .section: .callout
            }
        }
    }

    private let label: String
    private let prominence: Prominence

    public init(label: String, prominence: Prominence) {
        self.label = label
        self.prominence = prominence
    }

    public var body: some View {
        HStack(spacing: Theme.Space.x2) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(prominence.controlSize)
            Text(label)
                .font(prominence.font)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        // One element, not a spinner plus a label: the spinner has nothing of its
        // own to announce, and VoiceOver reading an unlabelled progress control
        // before the phase is noise in front of the only useful part.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
