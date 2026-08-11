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
enum ContrastEvidence {
    /// The WCAG AA ratio for normal text, which is also what the audit enforces.
    /// Applied uniformly — large text is allowed 3:1, so re-measuring against 4.5
    /// never clears something the audit would hold to a stricter bar.
    static let aaContrast = 4.5

    /// The ratio under which a cluster reads as background texture rather than an
    /// ink. See the type-level comment for what that trades away.
    static let textureCeiling = 1.15

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

        let inks = candidates.filter {
            contrast(luminance($0), backgroundLuminance) >= aaContrast
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

    /// Whether `color` lies on the straight sRGB line between `ink` and
    /// `background` — the only colors antialiasing `ink` over `background` can
    /// produce. Projects onto the segment and accepts a residual of at most 8
    /// (Euclidean, 0–255 channels); measured blends on real captures land under 1.
    private static func isBlend(_ color: UInt32, of ink: UInt32, over background: UInt32) -> Bool {
        func channels(_ packed: UInt32) -> [Double] {
            [Double((packed >> 16) & 0xFF), Double((packed >> 8) & 0xFF), Double(packed & 0xFF)]
        }
        let c = channels(color)
        let i = channels(ink)
        let b = channels(background)
        let direction = zip(i, b).map(-)
        let offset = zip(c, b).map(-)
        let lengthSquared = direction.map { $0 * $0 }.reduce(0, +)
        guard lengthSquared > 0 else { return false }
        let fraction = zip(offset, direction).map(*).reduce(0, +) / lengthSquared
        guard (0.0...1.0).contains(fraction) else { return false }
        let residual = zip(offset, direction.map { $0 * fraction }).map(-).map { $0 * $0 }.reduce(0, +)
        return residual <= 64
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
