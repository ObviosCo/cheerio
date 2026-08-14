import CoreGraphics
import Foundation

/// The pixel half of the audit's suppression filter — the code that decides
/// whether a flagged element's own rendering *proves* it readable. It's a pure
/// function over pixels, factored out of `AccessibilityAuditTests` so
/// `ContrastEvidenceTests` can hold it to synthetic fixtures: the gate turns red
/// checks green, so the thing that needs regression tests most is that this
/// refuses to clear what it can't prove.
///
/// Returns the *minimum* contrast ratio among the region's inks, or nil when the
/// pixels can't be read as inks that all clear AA over one background. Nil means
/// "can't be cleared", never "fine".
///
/// The most frequent color is the background. Every other color covering a
/// meaningful share of the *non-background* pixels (≥ 1% of what's drawn, floor
/// 3 — below that it's a stray remnant, not a glyph; the floor is sized to the
/// drawn pixels rather than the frame's area because a two-line label in a wide,
/// mostly-blank frame rendered its whole ink core in under 0.5% of the region)
/// must then be one of exactly three things, or the whole measurement is nil:
///
/// - **a passing ink** — contrast ≥ 4.5:1 against the background;
/// - **antialiasing of a passing ink** — geometrically a blend, lying on the
///   straight line between some passing ink and the background in sRGB, the only
///   colors text antialiasing can produce (macOS blends grayscale-AA text in
///   gamma space; measured residuals on real captures are under one channel
///   step, against a tolerance of 8);
/// - **background texture** — within 1.15:1 of the background, the variation a
///   translucent sidebar material produces (measured up to 1.10:1). A real ink
///   that faint is indistinguishable from texture by pixels, and also
///   invisible — far below even #141's failing 2–2.5:1, so a regression of that
///   class still measures as an ink and still fails.
///
/// So every distinguishable ink must clear AA — a second, weaker ink can't hide
/// behind a stronger one unless it is *exactly* a blend of that ink with the
/// background (a gray between two grays), which pixels alone cannot tell apart
/// from antialiasing; that residual blind spot is accepted and written down
/// here. Anything structurally mixed — an icon, a border, a color off every
/// ink's blend line — and any flat region (nothing legible rendered where the
/// frame claims) returns nil and stays red.
///
/// Not "the ink must be the most common cluster": at 1x, a caption's sub-pixel
/// strokes render mostly as midtones, so the core color is routinely a minority
/// of a small glyph's coverage — one run measured the passing token at 8 pixels
/// under a 19-pixel midtone.
///
/// A glyph thin enough has no repeated color at all, which is why ``rampInk``
/// exists alongside the significance floor: see it for the case where every
/// pixel drawn is a partial blend and the ink is only ever implied.
enum ContrastEvidence {
    /// The WCAG AA ratio for normal text, which is also what the audit enforces.
    /// Applied uniformly — large text is allowed 3:1, so re-measuring against 4.5
    /// never clears something the audit would hold to a stricter bar.
    static let aaContrast = 4.5

    /// The ratio under which a cluster reads as background texture rather than an
    /// ink. See the type-level comment for what that trades away.
    static let textureCeiling = 1.15

    /// How much of a pixel an ink has to cover for that pixel to count toward the
    /// ink's core in ``rampInk``: more ink than background. A pixel below this is
    /// mostly background, and a dark color reached by nothing but such pixels is a
    /// stray rather than a stroke.
    static let coreCoverage = 0.5

    /// Rasterizes and measures — the entry the audit uses.
    static func measuredTextContrast(in cgImage: CGImage) -> Double? {
        guard let pixels = rgbaPixels(of: cgImage) else { return nil }
        return measuredTextContrast(width: cgImage.width, height: cgImage.height, rgbaPixels: pixels)
    }

    /// The relative luminance of the region's dominant color — how the audits
    /// verify that `-screenshotAppearance` actually took effect, by reading the
    /// rendered window rather than trusting the launch argument: every surface
    /// token sits far above 0.5 in light mode and far below it in dark.
    static func dominantLuminance(in cgImage: CGImage) -> Double? {
        guard let pixels = rgbaPixels(of: cgImage) else { return nil }
        return dominantLuminance(width: cgImage.width, height: cgImage.height, rgbaPixels: pixels)
    }

    /// The pure form of ``dominantLuminance(in:)``, for the fixture tests.
    static func dominantLuminance(width: Int, height: Int, rgbaPixels: [UInt8]) -> Double? {
        guard width > 0, height > 0, rgbaPixels.count >= width * height * 4 else { return nil }
        var counts: [UInt32: Int] = [:]
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let key =
                UInt32(rgbaPixels[offset]) << 16 | UInt32(rgbaPixels[offset + 1]) << 8
                | UInt32(rgbaPixels[offset + 2])
            counts[key, default: 0] += 1
        }
        guard let dominant = counts.max(by: { $0.value < $1.value }) else { return nil }
        return luminance(dominant.key)
    }

    private static func rgbaPixels(of cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// The pure measurement — what `ContrastEvidenceTests` pins down.
    static func measuredTextContrast(width: Int, height: Int, rgbaPixels: [UInt8]) -> Double? {
        guard width > 0, height > 0, rgbaPixels.count >= width * height * 4 else { return nil }
        var counts: [UInt32: Int] = [:]
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let key =
                UInt32(rgbaPixels[offset]) << 16 | UInt32(rgbaPixels[offset + 1]) << 8
                | UInt32(rgbaPixels[offset + 2])
            counts[key, default: 0] += 1
        }
        guard let background = counts.max(by: { $0.value < $1.value }) else { return nil }
        let significant = max(3, (width * height - background.value) / 100)
        let backgroundLuminance = luminance(background.key)
        let candidates = counts.keys.filter { $0 != background.key && counts[$0]! >= significant }

        var inks = Set(
            candidates.filter {
                contrast(luminance($0), backgroundLuminance) >= aaContrast
            }
        )
        if let ramp = rampInk(counts: counts, background: background.key, significant: significant) {
            inks.insert(ramp)
        }
        guard !inks.isEmpty else { return nil }
        for color in candidates {
            let ratio = contrast(luminance(color), backgroundLuminance)
            if ratio >= aaContrast || ratio <= textureCeiling { continue }
            guard inks.contains(where: { isBlend(color, of: $0, over: background.key) }) else {
                return nil
            }
        }
        return inks.map { contrast(luminance($0), backgroundLuminance) }.min()
    }

    /// The ink a glyph too thin to fully cover a pixel still proves.
    ///
    /// The case, measured: the "3" in the empty-state dashboard's stats renders 47
    /// drawn pixels across 43 distinct colors on the runner's 1x display, none of
    /// them appearing more than twice. No color reaches the significance floor, so
    /// the loop above sees no ink at all and a region whose deepest pixel *is* the
    /// `Text/Primary` token — 17.3:1 against the white it sits on — came back nil
    /// and failed the audit (#184). Raising the floor or excusing digits would both
    /// miss what's actually there: a ramp. Antialiasing one ink over one background
    /// is the only thing that puts every drawn color on a single straight line to a
    /// single deepest color, and moving along that line away from the background
    /// only ever raises contrast, so the deepest color is a floor on the ink's
    /// ratio, never a flattering read of it.
    ///
    /// Three conditions, each closing a way this could excuse something real:
    ///
    /// - **the deepest drawn color clears AA.** It's the ink the ramp points at; if
    ///   it fails, the text fails, which is what keeps genuinely low-contrast text
    ///   (a #949494 caption and its own blends) red.
    /// - **every drawn color is a blend of it.** A second ink of any other hue — an
    ///   icon, a border, a chip — puts a color off that line and refuses the whole
    ///   measurement rather than hiding under the deepest one. This is stricter
    ///   than the loop above, which only asks that of colors above the floor,
    ///   because a thin ink's colors are all *below* the floor by construction.
    /// - **the ink's core clears the significance floor** — pixels it covers at
    ///   least ``coreCoverage`` of. Without that, one stray dark pixel would vouch
    ///   for a whole region of failing gray text: a failing gray ink and its blends
    ///   sit on the same line as any darker color, so a plateau of #949494 with a
    ///   lone black speck in it satisfies both conditions above while reaching a
    ///   core of exactly one pixel.
    ///
    /// The rule can only ever *add* an ink that clears AA, so it can turn a nil
    /// into a passing ratio and never a passing ratio into a failure — no finding
    /// this classifier already suppresses changes verdict because of it.
    private static func rampInk(counts: [UInt32: Int], background: UInt32, significant: Int) -> UInt32? {
        let backgroundLuminance = luminance(background)
        // What the region drew, reading near-background variation as texture
        // exactly as the caller does.
        let drawn = counts.filter {
            $0.key != background
                && contrast(luminance($0.key), backgroundLuminance) > textureCeiling
        }
        // Ties broken on the packed value so the answer never depends on dictionary
        // ordering.
        guard
            let deepest = drawn.keys.max(by: {
                (distanceSquared($0, background), $0) < (distanceSquared($1, background), $1)
            }),
            contrast(luminance(deepest), backgroundLuminance) >= aaContrast
        else { return nil }

        var core = 0
        for (color, count) in drawn {
            guard let coverage = blendCoverage(color, of: deepest, over: background) else { return nil }
            if coverage >= coreCoverage { core += count }
        }
        return core >= significant ? deepest : nil
    }

    /// Whether `color` lies on the straight sRGB line between `ink` and
    /// `background` — the only colors antialiasing `ink` over `background` can
    /// produce.
    private static func isBlend(_ color: UInt32, of ink: UInt32, over background: UInt32) -> Bool {
        blendCoverage(color, of: ink, over: background) != nil
    }

    /// How much of `ink` `color` is: its position along the straight sRGB line from
    /// `background` to `ink`, or nil when it isn't on that line at all. Projects
    /// onto the segment and accepts a residual of at most 8 (Euclidean, 0–255
    /// channels); measured blends on real captures land under 1.
    private static func blendCoverage(_ color: UInt32, of ink: UInt32, over background: UInt32) -> Double? {
        let c = channels(color)
        let i = channels(ink)
        let b = channels(background)
        let direction = zip(i, b).map(-)
        let offset = zip(c, b).map(-)
        let lengthSquared = direction.map { $0 * $0 }.reduce(0, +)
        guard lengthSquared > 0 else { return nil }
        let fraction = zip(offset, direction).map(*).reduce(0, +) / lengthSquared
        guard (0.0...1.0).contains(fraction) else { return nil }
        let residual = zip(offset, direction.map { $0 * fraction }).map(-).map { $0 * $0 }.reduce(0, +)
        return residual <= 64 ? fraction : nil
    }

    /// Squared sRGB distance, for ordering colors by how far from the background
    /// they are — squared because only the ordering is used.
    private static func distanceSquared(_ color: UInt32, _ other: UInt32) -> Double {
        zip(channels(color), channels(other)).map(-).map { $0 * $0 }.reduce(0, +)
    }

    private static func channels(_ packed: UInt32) -> [Double] {
        [Double((packed >> 16) & 0xFF), Double((packed >> 8) & 0xFF), Double(packed & 0xFF)]
    }

    /// WCAG 2.1 contrast ratio between two relative luminances.
    private static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// WCAG 2.1 relative luminance of a packed sRGB pixel.
    private static func luminance(_ packed: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let c = Double(channel) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear((packed >> 16) & 0xFF)
            + 0.7152 * linear((packed >> 8) & 0xFF)
            + 0.0722 * linear(packed & 0xFF)
    }
}
