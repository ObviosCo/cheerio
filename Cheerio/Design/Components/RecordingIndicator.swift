import SwiftUI

/// Recording state, with the three-signal rule enforced by construction.
///
/// Any surface that shows one signal must show all three: the **filled ring**,
/// the word **Recording**, and the **elapsed timer** in monospaced digits.
/// There is no initialiser that gives you a bare dot, which is the point —
/// the sidebar, the recording view and the header can't drift apart again.
///
/// Copper, not red. The distinction between idle and capturing is a *shape*
/// change (empty ring → filled ring), so it survives the menu bar's monochrome
/// template rendering, where colour isn't available at all.
public struct RecordingIndicator: View {
    private let isRecording: Bool
    private let elapsed: Duration

    public init(isRecording: Bool, elapsed: Duration) {
        self.isRecording = isRecording
        self.elapsed = elapsed
    }

    public var body: some View {
        HStack(spacing: Theme.Space.x2) {
            RecordingRing(isFilled: isRecording, diameter: 10)
            Text(isRecording ? "Recording" : "Idle")
                .font(.caption)
                .fontWeight(.semibold)
            if isRecording {
                Text(elapsed.formatted(.time(pattern: .minuteSecond)))
                    .chText(.elapsedTimer)
                    .font(.caption)
            }
        }
        .foregroundStyle(isRecording ? Theme.Colors.recording : Theme.Colors.textSecondary)
        .chAnimation(value: isRecording)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRecording ? "Recording, \(elapsed.formatted(.time(pattern: .minuteSecond))) elapsed" : "Not recording")
    }
}

/// The ring on its own — for the menu-bar template image and the record button,
/// where the word and the timer live elsewhere in the same view.
///
/// Takes its colour from the enclosing `foregroundStyle`, which is what lets the
/// same view be copper in the app and a single-colour template in the menu bar.
/// Set that style on the parent; don't reach for `.tint`.
public struct RecordingRing: View {
    private let isFilled: Bool
    private let diameter: CGFloat

    public init(isFilled: Bool, diameter: CGFloat) {
        self.isFilled = isFilled
        self.diameter = diameter
    }

    public var body: some View {
        // `.foreground`, never `.tint` — tint is the system accent and the user
        // can change it in System Settings. The ring is copper or it is nothing.
        Circle()
            .strokeBorder(.foreground, lineWidth: max(1.5, diameter * 0.28))
            .background(Circle().fill(isFilled ? AnyShapeStyle(.foreground) : AnyShapeStyle(.clear)))
            .frame(width: diameter, height: diameter)
            .chAnimation(Theme.Motion.fast, value: isFilled)
    }
}
