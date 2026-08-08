import AppKit
import CheerioKit

/// The menu-bar glyph: a monochrome, template-rendered treatment of the app
/// icon's copper ring (`Scripts/render-appicon.swift`), one variant per
/// `CaptureSession.State` so "is it recording" reads at a glance (issue #49).
///
/// **Generated at runtime, not as committed PNGs.** `render-appicon.swift`
/// generates because ten sizes of a two-color gradient are worth a script and
/// a build artifact. A monochrome 18pt glyph is a handful of `CGPath`
/// operations on constants shared with that script's ratios — there's nothing
/// here a PNG round-trip would buy over drawing it directly, and drawing it in
/// Swift means the geometry has exactly one copy, with no asset-catalog
/// `Contents.json` and no "did you re-run the script" step to forget.
/// `NSImage(size:flipped:drawingHandler:)` asks AppKit for whatever backing
/// scale it needs (1x/2x) at draw time, so there's no manual multi-resolution
/// bookkeeping either — that's the other thing the asset-catalog route would
/// have bought, and it comes for free here. `isTemplate = true` is what makes
/// it a template image: only the alpha channel matters, and macOS tints the
/// result for light/dark menu bars and Control Center.
enum MenuBarIcon {
    /// Menu-bar template images live on an 18×18pt grid
    /// (docs/DESIGN-HANDOFF.md §2).
    static let pointSize: CGFloat = 18

    /// Ring centerline radius and stroke thickness, as fractions of the
    /// drawing's side length. These are the same ratios
    /// `Scripts/render-appicon.swift`'s `spec(forPixels:)` uses for its
    /// smallest slots (`radius: 27.0, stroke: 21.0` on a 100-unit grid) —
    /// the thickest ring in that script, because that's the one already
    /// tuned to stay legible at a size close to this one.
    private static let radiusFraction: CGFloat = 0.27
    private static let strokeFraction: CGFloat = 0.21

    /// Renders the template image for one session state. Cheap enough to call
    /// on every state change — a handful of ellipses on an 18pt canvas — so
    /// there's no cache to invalidate.
    static func image(for state: CaptureSession.State) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, in: rect, context: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.menuBarAccessibilityLabel
        return image
    }

    private static func draw(_ state: CaptureSession.State, in rect: CGRect, context ctx: CGContext) {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = side * radiusFraction
        let stroke = side * strokeFraction
        let outerRadius = radius + stroke / 2
        let innerRadius = radius - stroke / 2

        // The annulus itself: two nested circles, filled even-odd so the
        // inside of the inner circle is a hole. Every state below starts from
        // this same ring — only what's added inside it differs.
        func ringPath() -> CGMutablePath {
            let path = CGMutablePath()
            path.addEllipse(
                in: CGRect(
                    x: center.x - outerRadius, y: center.y - outerRadius,
                    width: outerRadius * 2, height: outerRadius * 2))
            path.addEllipse(
                in: CGRect(
                    x: center.x - innerRadius, y: center.y - innerRadius,
                    width: innerRadius * 2, height: innerRadius * 2))
            return path
        }

        func dot(radius dotRadius: CGFloat, offsetX: CGFloat = 0) -> CGRect {
            CGRect(
                x: center.x + offsetX - dotRadius, y: center.y - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2)
        }

        ctx.setFillColor(NSColor.black.cgColor)  // Color is ignored under isTemplate; alpha is what draws.

        switch state {
        case .idle:
            // Plain ring: not recording, nothing more to say.
            ctx.addPath(ringPath())
            ctx.fillPath(using: .evenOdd)

        case .preparingModel:
            // Half ring: visibly incomplete, the same idea as a half-drawn
            // progress ring — getting ready, not ready yet.
            ctx.saveGState()
            ctx.addPath(ringPath())
            ctx.clip(using: .evenOdd)
            ctx.fill(CGRect(x: rect.minX, y: center.y, width: rect.width, height: rect.maxY - center.y))
            ctx.restoreGState()

        case .recording:
            // Full ring plus a solid center dot. This is the one state that
            // must never be mistaken for another, so it gets the heaviest
            // treatment — the whole shape, not a variation on it.
            let path = ringPath()
            let dotRadius = innerRadius * 0.55
            path.addEllipse(in: dot(radius: dotRadius))
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)

        case .finishing:
            // Ring plus a small ellipsis, echoing the `ellipsis.circle` SF
            // Symbol this replaces so the "still working" meaning carries
            // over rather than being invented from scratch.
            let path = ringPath()
            let dotRadius = innerRadius * 0.16
            let spacing = dotRadius * 3.4
            for offset in [-spacing, 0, spacing] {
                path.addEllipse(in: dot(radius: dotRadius, offsetX: offset))
            }
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        }
    }
}

extension CaptureSession.State {
    /// VoiceOver text for the menu-bar glyph — the icon alone can't be the only
    /// signal (docs/DESIGN-HANDOFF.md §4's "no state communicated by color
    /// alone" bar extends to shape-alone for assistive tech).
    var menuBarAccessibilityLabel: String {
        switch self {
        case .idle: "Cheerio: not recording"
        case .preparingModel: "Cheerio: preparing to record"
        case .recording: "Cheerio: recording"
        case .finishing: "Cheerio: finishing up"
        }
    }
}
