import AppKit
import CheerioKit

/// The menu-bar glyph: a monochrome, template-rendered treatment of the app
/// icon's copper ring (`Scripts/render-appicon.swift`), one variant per
/// ``MenuBarIcon/Status`` so "is it recording" reads at a glance (issue #49) —
/// and, since #173, so does "is it still working on the last one".
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
    /// What the glyph is depicting.
    ///
    /// `CaptureSession.State` can't be the whole story: a meeting being diarized
    /// and written up by launch recovery, or by a re-identify pass, runs while the
    /// session sits at `.idle` (issue #173), so a menu bar reading the state alone
    /// shows the plain idle ring through the whole of it. Capture still wins
    /// whenever there is any — a recording in progress is the one thing this glyph
    /// must never fail to report — so background processing only claims the glyph
    /// at `.idle`; see `CaptureSession.menuBarStatus`.
    enum Status: Equatable {
        case session(CaptureSession.State)
        /// Nothing is being captured, but a meeting's pipeline is running.
        case processingInBackground
    }

    /// Menu-bar template images live on an 18×18pt grid
    /// (docs/DESIGN-HANDOFF.md §2) — the same constant `RecordingRing` uses,
    /// so the app's own recording ring and this monochrome one never drift apart.
    static let pointSize: CGFloat = Theme.Layout.menuBarGlyph

    /// Ring centerline radius, as a fraction of the drawing's side length —
    /// the same ratio `Scripts/render-appicon.swift`'s `spec(forPixels:)` uses
    /// for its smallest slots (`radius: 27.0` on a 100-unit grid).
    private static let radiusFraction: CGFloat = 0.27

    /// Renders the template image for one status. Cheap enough to call on every
    /// state change — a handful of ellipses on an 18pt canvas — so there's no
    /// cache to invalidate.
    static func image(for status: Status) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(status, in: rect, context: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = status.menuBarAccessibilityLabel
        return image
    }

    private static func draw(_ status: Status, in rect: CGRect, context ctx: CGContext) {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = side * radiusFraction
        // Same formula `RecordingRing` strokes its own circle with, so the two
        // rings stay proportionally identical wherever `menuBarGlyph` lands.
        let stroke = max(1.5, side * 0.28)
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

        switch status {
        case .session(.idle):
            // Plain ring: not recording, nothing more to say.
            ctx.addPath(ringPath())
            ctx.fillPath(using: .evenOdd)

        case .session(.preparingModel):
            // Half ring: visibly incomplete, the same idea as a half-drawn
            // progress ring — getting ready, not ready yet.
            ctx.saveGState()
            ctx.addPath(ringPath())
            ctx.clip(using: .evenOdd)
            ctx.fill(CGRect(x: rect.minX, y: center.y, width: rect.width, height: rect.maxY - center.y))
            ctx.restoreGState()

        case .session(.recording):
            // Full ring plus a solid center dot. This is the one state that
            // must never be mistaken for another, so it gets the heaviest
            // treatment — the whole shape, not a variation on it.
            let path = ringPath()
            let dotRadius = innerRadius * 0.55
            path.addEllipse(in: dot(radius: dotRadius))
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)

        case .session(.holding):
            // Ring plus a *hollow* center dot — the recording state's solid dot
            // with its middle waiting to be filled in: captured, not yet
            // processed. Distinct at a glance from `.recording` (solid) and
            // `.finishing` (ellipsis), which matters because this is the one
            // state that's waiting on the user rather than on the machine.
            //
            // The hole is a proportion of the dot, never a stroke-width
            // subtraction: on the 18pt canvas the dot's radius is ~1.3pt while
            // the ring's stroke is ~5pt, so anything derived from the stroke
            // swallows the dot whole — a negative inner radius, no hole, and a
            // `.holding` glyph indistinguishable from `.recording`.
            let path = ringPath()
            let dotRadius = innerRadius * 0.55
            let holeRadius = dotRadius * 0.55
            path.addEllipse(in: dot(radius: dotRadius))
            path.addEllipse(in: dot(radius: holeRadius))
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)

        case .session(.finishing), .processingInBackground:
            // Ring plus a small ellipsis, echoing the `ellipsis.circle` SF
            // Symbol this replaces so the "still working" meaning carries
            // over rather than being invented from scratch.
            //
            // One glyph for both, deliberately: to the person reading the menu
            // bar, a meeting being processed at the end of a recording and one
            // being processed by launch recovery are the same fact — the machine
            // is working through a meeting — and inventing a sixth shape to
            // separate them would spend the 18pt canvas's last legible
            // distinction on which code path started it. Which meeting, and how
            // far along, is what the panel below and the library row say; the
            // two do get their own VoiceOver wording (see
            // ``Status/menuBarAccessibilityLabel``).
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

extension MenuBarIcon.Status {
    /// VoiceOver text for the menu-bar glyph — the icon alone can't be the only
    /// signal (docs/DESIGN-HANDOFF.md §4's "no state communicated by color
    /// alone" bar extends to shape-alone for assistive tech).
    ///
    /// The one place the shared `.finishing` glyph is spelled out as two
    /// different things: shape has to be economical at 18pt, words don't.
    var menuBarAccessibilityLabel: String {
        switch self {
        case .session(.idle): "Cheerio: not recording"
        case .session(.preparingModel): "Cheerio: preparing to record"
        case .session(.recording): "Cheerio: recording"
        case .session(.holding): "Cheerio: waiting to process"
        case .session(.finishing): "Cheerio: finishing up"
        case .processingInBackground: "Cheerio: processing a meeting"
        }
    }
}
