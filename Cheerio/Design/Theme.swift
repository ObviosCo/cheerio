import SwiftUI

/// Cheerio's design tokens, in one place.
///
/// Colour lives in `Assets.xcassets` (see `docs/token-map.md`) and is reached
/// through `Theme.Colors`. Everything that isn't a colour lives here as plain
/// values. Nothing in the app should hard-code a hex, a corner radius, or a
/// duration — if a value is missing, add it here rather than inline.
public enum Theme {

    // MARK: Spacing — 4 pt grid

    public enum Space {
        public static let x1: CGFloat = 4
        public static let x2: CGFloat = 8
        public static let x3: CGFloat = 12
        public static let x4: CGFloat = 16
        public static let x6: CGFloat = 24
        public static let x8: CGFloat = 32
        public static let x12: CGFloat = 48
        public static let x16: CGFloat = 64
        public static let x24: CGFloat = 96
    }

    // MARK: Radii — 8 is the workhorse

    public enum Radius {
        public static let sm: CGFloat = 4
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
        /// Use with `Capsule()` in preference to a large number where you can.
        public static let full: CGFloat = 999
    }

    // MARK: Motion — quiet, certain, no bounce

    public enum Motion {
        public static let fast: Double = 0.12
        public static let standard: Double = 0.20
        public static let slow: Double = 0.36

        private static let curve = UnitCurve.bezier(
            startControlPoint: UnitPoint(x: 0.16, y: 1),
            endControlPoint: UnitPoint(x: 0.30, y: 1)
        )

        public static func animation(_ duration: Double = standard) -> Animation {
            .timingCurve(curve, duration: duration)
        }

        /// The only moment in the app worth animating: chips arriving when
        /// identification finishes. A settling, not a reveal.
        public static let chipsArriving = animation(standard)
    }

    // MARK: Layout constants that were once magic numbers

    public enum Layout {
        /// The transcript speaker rail. A *minimum*, never a fixed width — a
        /// pinned 72 pt clips at larger Dynamic Type sizes.
        public static let speakerRailMinWidth: CGFloat = 72
        public static let speakerRailMaxWidth: CGFloat = 148
        public static let chipDiameter: CGFloat = 22
        public static let chipRingInset: CGFloat = -3
        /// The menu-bar template image. Single-colour by definition, so the
        /// ring's fill state has to read unmistakably at this size.
        public static let menuBarGlyph: CGFloat = 18
        /// The speakers panel's talk-time strip. Thin enough to read as a
        /// texture under the panel header, not another control competing with
        /// the rows below it.
        public static let speakerTimelineHeight: CGFloat = 5
    }
}

// MARK: - Reduce Motion

public extension View {
    /// Applies a Cheerio animation, collapsing it to nothing when the user has
    /// asked for reduced motion. Prefer this over calling `.animation` directly
    /// so no component has to remember the accessibility check.
    func chAnimation<V: Equatable>(_ duration: Double = Theme.Motion.standard, value: V) -> some View {
        modifier(CheerioAnimation(duration: duration, value: value))
    }
}

private struct CheerioAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let duration: Double
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : Theme.Motion.animation(duration), value: value)
    }
}
