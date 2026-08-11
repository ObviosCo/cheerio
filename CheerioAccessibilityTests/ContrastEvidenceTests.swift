import XCTest

/// Pins ``ContrastEvidence`` to synthetic fixtures. This is the negative control
/// for the audit's suppression filter: the classifier is the code that turns red
/// checks green, so the property that has to survive future edits is that it
/// *refuses* — a flat region, genuinely low-contrast text, and anything it can't
/// prove must come back nil, while the two artifact shapes it exists to excuse
/// (passing antialiased text, background texture) must come back with the ink's
/// measured ratio.
///
/// Plain unit tests inside the UI-testing bundle, deliberately: nothing here
/// launches the app — the fixtures are hand-built pixel buffers fed to the same
/// pure function the audit calls on real element screenshots.
final class ContrastEvidenceTests: XCTestCase {
    /// `Text/Secondary` light (#606468) on white — 5.97:1, the app's workhorse
    /// caption pairing.
    private static let token: (UInt8, UInt8, UInt8) = (96, 100, 104)
    private static let white: (UInt8, UInt8, UInt8) = (255, 255, 255)

    // MARK: - Must refuse

    /// Nothing legible rendered where the frame claims — the audit sampled a
    /// blank region, and blankness proves nothing about the element's colors.
    /// This is also the white-on-white shape: refusal is what keeps invisible
    /// text a failure.
    func testFlatRegionIsNotClearable() {
        let pixels = Self.image(width: 40, height: 12) { _, _ in Self.white }
        XCTAssertNil(ContrastEvidence.measuredTextContrast(width: 40, height: 12, rgbaPixels: pixels))
    }

    /// Genuinely failing text — #949494 on white is 2.98:1, the #141 class. There
    /// is no passing ink anywhere in the region, so nothing can vouch for it.
    func testLowContrastTextIsNotClearable() {
        let ink: (UInt8, UInt8, UInt8) = (148, 148, 148)
        let pixels = Self.glyphRamp(ink: ink, background: Self.white, width: 40, height: 12)
        XCTAssertNil(ContrastEvidence.measuredTextContrast(width: 40, height: 12, rgbaPixels: pixels))
    }

    /// Copilot's compound-element hazard: a minority high-contrast ink (near-black)
    /// next to a failing *colored* ink (a desaturated red at ~3.1:1). The red sits
    /// off the black↔white blend line, so the black must not vouch for it.
    func testHighContrastInkCannotVouchForOffLineInk() {
        let black: (UInt8, UInt8, UInt8) = (23, 27, 31)
        let red: (UInt8, UInt8, UInt8) = (220, 90, 90)
        let pixels = Self.image(width: 40, height: 12) { x, _ in
            switch x % 10 {
            case 0: black
            case 5, 6: red
            default: Self.white
            }
        }
        XCTAssertNil(ContrastEvidence.measuredTextContrast(width: 40, height: 12, rgbaPixels: pixels))
    }

    /// Degenerate inputs prove nothing.
    func testEmptyAndMismatchedBuffersAreNotClearable() {
        XCTAssertNil(ContrastEvidence.measuredTextContrast(width: 0, height: 0, rgbaPixels: []))
        XCTAssertNil(ContrastEvidence.measuredTextContrast(width: 4, height: 4, rgbaPixels: [0, 0, 0, 255]))
    }

    // MARK: - Must clear, at the measured ratio

    /// The 1x antialiasing artifact this classifier exists for: a passing token
    /// whose midtones outnumber its core pixels. The measurement is the *ink's*
    /// ratio — the midtones are excused as blends, never averaged in.
    func testPassingAntialiasedTextClears() throws {
        let pixels = Self.glyphRamp(ink: Self.token, background: Self.white, width: 40, height: 12)
        let measured = try XCTUnwrap(
            ContrastEvidence.measuredTextContrast(width: 40, height: 12, rgbaPixels: pixels)
        )
        XCTAssertEqual(measured, 5.97, accuracy: 0.05)
    }

    /// Two inks, both passing — the combined markdown row's shape (marker in the
    /// token, body near-black). The reported ratio is the *minimum*: the weaker
    /// ink is what the element is only as readable as.
    func testTwoPassingInksClearAtTheWeakerRatio() throws {
        let body: (UInt8, UInt8, UInt8) = (23, 27, 31)
        let pixels = Self.image(width: 40, height: 12) { x, _ in
            switch x % 8 {
            case 0: Self.token
            case 4: body
            default: Self.white
            }
        }
        let measured = try XCTUnwrap(
            ContrastEvidence.measuredTextContrast(width: 40, height: 12, rgbaPixels: pixels)
        )
        XCTAssertEqual(measured, 5.97, accuracy: 0.05)
    }

    /// The wide-frame regression: a two-line label in a mostly-blank region put
    /// its whole ink core in under 0.5% of the area, and a significance floor
    /// keyed on the frame's size demoted the ink to noise — this fixture's 20
    /// ink pixels sit under that old floor (area/200 = 30) and over the current
    /// one, which scales with what's drawn.
    func testSmallInkInAWideFrameStillCounts() throws {
        let pixels = Self.image(width: 200, height: 30) { x, y in
            guard y == 15 else { return Self.white }
            if (40..<60).contains(x) { return Self.token }
            if (60..<85).contains(x) { return (176, 178, 180) }
            return Self.white
        }
        let measured = try XCTUnwrap(
            ContrastEvidence.measuredTextContrast(width: 200, height: 30, rgbaPixels: pixels)
        )
        XCTAssertEqual(measured, 5.97, accuracy: 0.05)
    }

    /// The sidebar-material shape: near-background shades on *both* sides of the
    /// most common color (a translucent material's texture), which no blend of
    /// ink-over-background can produce, plus a passing ink. Texture within
    /// 1.15:1 is excused; the ink's ratio comes back.
    func testBackgroundTextureIsExcused() throws {
        let material: (UInt8, UInt8, UInt8) = (242, 242, 242)
        let lighter: (UInt8, UInt8, UInt8) = (250, 250, 250)
        let darker: (UInt8, UInt8, UInt8) = (238, 238, 238)
        let pixels = Self.image(width: 40, height: 12) { x, y in
            if x % 10 == 0 { return Self.token }
            if (x + y) % 7 == 0 { return lighter }
            if (x + y) % 11 == 0 { return darker }
            return material
        }
        let measured = try XCTUnwrap(
            ContrastEvidence.measuredTextContrast(width: 40, height: 12, rgbaPixels: pixels)
        )
        XCTAssertEqual(measured, 5.33, accuracy: 0.05)
    }

    // MARK: - Appearance reading

    /// `dominantLuminance` is how the suite verifies `-screenshotAppearance`
    /// took effect — it has to read a light surface as light and a dark one as
    /// dark even with a full page of text on it.
    func testDominantLuminanceReadsTheSurface() throws {
        let lightPage = Self.glyphRamp(ink: Self.token, background: Self.white, width: 40, height: 12)
        let light = try XCTUnwrap(
            ContrastEvidence.dominantLuminance(width: 40, height: 12, rgbaPixels: lightPage)
        )
        XCTAssertGreaterThan(light, 0.5)

        let darkSurface: (UInt8, UInt8, UInt8) = (28, 34, 44)
        let darkInk: (UInt8, UInt8, UInt8) = (235, 239, 242)
        let darkPage = Self.glyphRamp(ink: darkInk, background: darkSurface, width: 40, height: 12)
        let dark = try XCTUnwrap(
            ContrastEvidence.dominantLuminance(width: 40, height: 12, rgbaPixels: darkPage)
        )
        XCTAssertLessThan(dark, 0.5)

        XCTAssertNil(ContrastEvidence.dominantLuminance(width: 0, height: 0, rgbaPixels: []))
    }

    // MARK: - Fixtures

    /// A buffer painted per-pixel.
    private static func image(
        width: Int,
        height: Int,
        paint: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) -> [UInt8] {
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = paint(x, y)
                pixels.append(contentsOf: [r, g, b, 255])
            }
        }
        return pixels
    }

    /// What small antialiased text actually looks like in a histogram: a minority
    /// of core-ink pixels under a larger population of gamma-space blends toward
    /// the background — the exact shape measured on the CI runner's captures.
    private static func glyphRamp(
        ink: (UInt8, UInt8, UInt8),
        background: (UInt8, UInt8, UInt8),
        width: Int,
        height: Int
    ) -> [UInt8] {
        func blend(_ fraction: Double) -> (UInt8, UInt8, UInt8) {
            func mix(_ i: UInt8, _ b: UInt8) -> UInt8 {
                UInt8((fraction * Double(i) + (1 - fraction) * Double(b)).rounded())
            }
            return (mix(ink.0, background.0), mix(ink.1, background.1), mix(ink.2, background.2))
        }
        return image(width: width, height: height) { x, _ in
            switch x % 12 {
            case 0: ink
            case 1, 2: blend(0.55)
            case 3: blend(0.25)
            default: background
            }
        }
    }
}
