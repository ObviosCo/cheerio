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

    /// The same thin glyph the positive control below clears, drawn in a failing
    /// ink (#949494, 2.98:1 — 3:1 in round numbers). Nothing about a ramp excuses
    /// the ink it ramps *to*: the deepest pixel is the whole claim, and this one
    /// doesn't clear AA.
    func testThinAntialiasedTextInAFailingInkIsNotClearable() {
        let ink: (UInt8, UInt8, UInt8) = (148, 148, 148)
        let pixels = Self.thinGlyph(ink: ink, background: Self.white, width: 9, height: 17)
        XCTAssertNil(ContrastEvidence.measuredTextContrast(width: 9, height: 17, rgbaPixels: pixels))
    }

    /// The hazard the ink-core condition exists for: a plateau of genuinely
    /// failing gray text with one near-black pixel in it. The speck is on the same
    /// blend line as the gray — every neutral gray is — so without a core it would
    /// pass as "a thin black glyph whose ramp is that gray," clearing at 17:1 the
    /// exact regression class #141 was. One pixel is not a stroke.
    func testOneDarkPixelCannotVouchForFailingGrayText() {
        let gray: (UInt8, UInt8, UInt8) = (148, 148, 148)
        let speck: (UInt8, UInt8, UInt8) = (23, 27, 31)
        let pixels = Self.image(width: 40, height: 12) { x, y in
            if x == 20 && y == 6 { return speck }
            return x % 12 == 0 ? gray : Self.white
        }
        XCTAssertNil(ContrastEvidence.measuredTextContrast(width: 40, height: 12, rgbaPixels: pixels))
    }

    /// A thin passing glyph next to a handful of off-line colored pixels — too few
    /// to reach the significance floor, so the floor-keyed loop never asks about
    /// them. A ramp has to account for *everything* drawn or it isn't one glyph's
    /// antialiasing, which is what stops a thin ink from vouching for a second ink
    /// it shares no blend line with.
    func testThinGlyphCannotVouchForOffLinePixels() {
        var pixels = Self.thinGlyph(ink: (23, 27, 31), background: Self.white, width: 9, height: 17)
        let red: (UInt8, UInt8, UInt8) = (220, 90, 90)
        for offset in [4 * (2 * 9 + 1), 4 * (3 * 9 + 1)] {
            pixels[offset] = red.0
            pixels[offset + 1] = red.1
            pixels[offset + 2] = red.2
        }
        XCTAssertNil(ContrastEvidence.measuredTextContrast(width: 9, height: 17, rgbaPixels: pixels))
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

    /// The thin-glyph artifact from #184, at the shape measured off the failing CI
    /// run: a 9×17 element holding the dashboard's "3" in `Text/Primary`, 47 drawn
    /// pixels across as many distinct coverages, no color repeated enough to reach
    /// the significance floor and not one of them fully inked. The ink is only ever
    /// implied by the ramp — and it's implied at 17.3:1, which is what this has to
    /// come back with rather than nil.
    func testThinAntialiasedTextWithNoSignificantInkClusterClears() throws {
        let pixels = Self.thinGlyph(ink: (23, 27, 31), background: Self.white, width: 9, height: 17)
        let measured = try XCTUnwrap(
            ContrastEvidence.measuredTextContrast(width: 9, height: 17, rgbaPixels: pixels)
        )
        XCTAssertEqual(measured, 17.31, accuracy: 0.05)
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
        image(width: width, height: height) { x, _ in
            switch x % 12 {
            case 0: ink
            case 1, 2: blend(ink, over: background, coverage: 0.55)
            case 3: blend(ink, over: background, coverage: 0.25)
            default: background
            }
        }
    }

    /// A glyph too thin to leave a *cluster*: every drawn pixel a different coverage
    /// of one ink, so no single color repeats often enough to reach the significance
    /// floor. (The deepest pixel is fully inked — one pixel, which is exactly the
    /// point: a lone sample is not a plateau the classifier can measure from.) What the classifier reads is a histogram rather than a shape,
    /// so this reproduces the population measured off #184's failing run — 47 drawn
    /// pixels in a 9×17 element, 43 distinct colors, none appearing more than twice
    /// — rather than the outline of a numeral.
    private static func thinGlyph(
        ink: (UInt8, UInt8, UInt8),
        background: (UInt8, UInt8, UInt8),
        width: Int,
        height: Int,
        drawnPixels: Int = 47
    ) -> [UInt8] {
        image(width: width, height: height) { x, y in
            let index = y * width + x
            guard index < drawnPixels else { return background }
            return blend(ink, over: background, coverage: Double(drawnPixels - index) / Double(drawnPixels))
        }
    }

    /// `coverage` of `ink` over `background`, mixed the way antialiasing mixes it.
    private static func blend(
        _ ink: (UInt8, UInt8, UInt8),
        over background: (UInt8, UInt8, UInt8),
        coverage: Double
    ) -> (UInt8, UInt8, UInt8) {
        func mix(_ i: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((coverage * Double(i) + (1 - coverage) * Double(b)).rounded())
        }
        return (mix(ink.0, background.0), mix(ink.1, background.1), mix(ink.2, background.2))
    }
}
