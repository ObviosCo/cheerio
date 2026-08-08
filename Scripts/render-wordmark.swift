#!/usr/bin/env swift
// Renders the Cheerio wordmark — "Cheeri" in Literata with the final o replaced
// by the app icon's ring — into site/logo/ as outlined, font-free SVG, plus the
// GitHub social card as PNG.
//
// Outlined on purpose: a README and a repo social card render SVG without the
// site's stylesheet, so live <text> would fall back to Times on someone else's
// machine. Everything this writes is pure geometry with no font dependency.
//
// The ring is not placed by eye. The word "Cheerio" is laid out in full, with
// the font's own kerning, and then the final o's outline is dropped and a true
// circle is put in the slot it vacated — same centre, same optical size. Change
// the tracking or the face and the ring follows on its own.
//
// One ring weight everywhere. The stroke is 24-28% of the ring's outer
// diameter depending on size, which is the ratio render-appicon.swift already
// uses (24.6% large, 28.0% small) — so the o in the wordmark and the ring in
// the Dock are one object at two sizes, not a resemblance. An earlier cut ran
// the in-word ring lighter to sit with Literata Regular and it read as a hole
// in the word. If the ring ever feels heavy, bring the word up to Literata
// Medium; do not thin the ring.
//
// Run from the repo root:  swift Scripts/render-wordmark.swift
//
// Flags:
//   --font <path>     TTF/OTF to set the word in   (default site/fonts/Literata-Regular.ttf)
//   --weight <n>      ring thickness as a percentage of its outer diameter
//                     (default 26 — the standard master; 24 display, 28 small)
//   --tracking <n>    letter tracking in 1/100 em   (default -1.4, matching 1a)
//   --out <dir>       output directory              (default site/logo)

import AppKit
import CoreText
import UniformTypeIdentifiers

// MARK: - Arguments

func flag(_ name: String, _ fallback: String) -> String {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

let fontPath = flag("font", "site/fonts/Literata-Regular.ttf")
let ringWeightPct = CGFloat(Double(flag("weight", "26")) ?? 26)
let tracking = CGFloat(Double(flag("tracking", "-1.4")) ?? -1.4)
let outDir = URL(fileURLWithPath: flag("out", "site/logo"))

// The word is set at 100 units to the em, so every number this script prints or
// writes is on the same 100-unit grid the icon script uses.
let em: CGFloat = 100

// MARK: - Colour

let navy = "#1E2B3F"
let copper = "#A87040"
let copperLight = "#D49E6C"
let warmWhite = "#FAFAF9"

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

// MARK: - Font

let fontURL = URL(fileURLWithPath: fontPath)
guard FileManager.default.fileExists(atPath: fontURL.path) else {
    FileHandle.standardError.write(Data("""
        Can't find a font at \(fontPath).

        The wordmark is set in Literata, SIL Open Font License 1.1. Download the
        static Regular from fonts.google.com/specimen/Literata, commit it to
        site/fonts/ alongside its OFL.txt, and re-run. Or point somewhere else:

            swift Scripts/render-wordmark.swift --font path/to/Face.ttf


        """.utf8))
    exit(1)
}

guard let provider = CGDataProvider(url: fontURL as CFURL),
      let cgFont = CGFont(provider) else {
    fatalError("couldn't read a font out of \(fontPath)")
}
let font = CTFontCreateWithGraphicsFont(cgFont, em, nil, nil)

// MARK: - Layout

// Lay out the whole word so the font's kerning between "i" and "o" is real.
let word = "Cheerio"
let attributed = NSAttributedString(string: word, attributes: [
    .font: font,
    .kern: tracking,
    .ligature: 1,
])
let line = CTLineCreateWithAttributedString(attributed)
let runs = CTLineGetGlyphRuns(line) as! [CTRun]

struct PlacedGlyph {
    let glyph: CGGlyph
    let position: CGPoint
    let font: CTFont
}

var placed: [PlacedGlyph] = []
for run in runs {
    let count = CTRunGetGlyphCount(run)
    guard count > 0 else { continue }
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
    let attrs = CTRunGetAttributes(run) as! [CFString: Any]
    let runFont = (attrs[kCTFontAttributeName] as! CTFont)
    for i in 0..<count {
        placed.append(PlacedGlyph(glyph: glyphs[i], position: positions[i], font: runFont))
    }
}

guard placed.count == word.count else {
    fatalError("""
        \(word) came back as \(placed.count) glyphs, not \(word.count). A ligature or a \
        substitution has fired, so the last glyph is no longer the o and the ring \
        would land in the wrong place. Re-run with --tracking 0, or disable the \
        offending feature, before trusting the output.
        """)
}

// The final o: dropped from the outline, its slot handed to the ring.
let oSlot = placed.removeLast()
var oGlyph = oSlot.glyph
let oBounds = CTFontGetBoundingRectsForGlyphs(oSlot.font, .horizontal, &oGlyph, nil, 1)

let ringCentre = CGPoint(x: oSlot.position.x + oBounds.midX,
                         y: oSlot.position.y + oBounds.midY)
// The o's own height sets the ring's outer diameter, so the ring picks up the
// overshoot a round letter already has and sits on the baseline correctly.
let ringOuterR = oBounds.height / 2
let ringStroke = ringOuterR * 2 * ringWeightPct / 100
let ringCentrelineR = ringOuterR - ringStroke / 2

// MARK: - Outlines

func svgPath(for g: PlacedGlyph) -> String {
    var glyph = g.glyph
    var transform = CGAffineTransform(translationX: g.position.x, y: g.position.y)
    guard let path = CTFontCreatePathForGlyph(g.font, glyph, &transform) else { return "" }
    _ = glyph

    var d = ""
    func n(_ v: CGFloat) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(format: "%.2f", r)
    }
    path.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint:
            d += "M\(n(p[0].x)) \(n(p[0].y))"
        case .addLineToPoint:
            d += "L\(n(p[0].x)) \(n(p[0].y))"
        case .addQuadCurveToPoint:
            d += "Q\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y))"
        case .addCurveToPoint:
            d += "C\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y)) \(n(p[2].x)) \(n(p[2].y))"
        case .closeSubpath:
            d += "Z"
        @unknown default:
            break
        }
    }
    return d
}

let letterPaths = placed.map(svgPath(for:)).filter { !$0.isEmpty }
guard !letterPaths.isEmpty else { fatalError("no outlines came back — is this a bitmap font?") }

// MARK: - Bounds

var inkBounds = CGRect.null
for g in placed {
    var glyph = g.glyph
    let b = CTFontGetBoundingRectsForGlyphs(g.font, .horizontal, &glyph, nil, 1)
    inkBounds = inkBounds.union(b.offsetBy(dx: g.position.x, dy: g.position.y))
}
inkBounds = inkBounds.union(CGRect(x: ringCentre.x - ringOuterR, y: ringCentre.y - ringOuterR,
                                   width: ringOuterR * 2, height: ringOuterR * 2))

// Clear space is one ring diameter on every side. The mark measures its own
// breathing room, so the rule needs no table and survives any scale.
let pad = ringOuterR * 2
let boxW = inkBounds.width + pad * 2
let boxH = inkBounds.height + pad * 2

func f(_ v: CGFloat) -> String {
    let r = (v * 100).rounded() / 100
    return r == r.rounded() ? String(Int(r)) : String(format: "%.2f", r)
}

// SVG's y runs downward and the font's runs up, so everything is emitted in
// font space and flipped once by the group transform.
let flip = "translate(\(f(pad - inkBounds.minX)) \(f(inkBounds.maxY + pad))) scale(1 -1)"

// MARK: - Writers

let provenance = """
<!-- Cheerio wordmark. Generated by Scripts/render-wordmark.swift — do not edit.
     Outlines from \(fontURL.lastPathComponent) (SIL Open Font License 1.1);
     the paths below are geometry, not font data. Ring weight \(f(ringWeightPct))% of
     outer diameter — the app icon's ratio. Tracking \(f(tracking))/100 em.
     Clear space on all sides is one ring diameter.
     MIT. -->
"""

func horizontal(wordFill: String, ringFill: String) -> String {
    """
    \(provenance)
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(f(boxW)) \(f(boxH))" \
    width="\(f(boxW))" height="\(f(boxH))" role="img" aria-label="Cheerio">
      <title>Cheerio</title>
      <g transform="\(flip)">
        <path fill="\(wordFill)" fill-rule="nonzero" d="\(letterPaths.joined())"/>
        <circle cx="\(f(ringCentre.x))" cy="\(f(ringCentre.y))" r="\(f(ringCentrelineR))" \
    fill="none" stroke="\(ringFill)" stroke-width="\(f(ringStroke))"/>
      </g>
    </svg>

    """
}

// Stacked: the ring lifts off the word and the word keeps its own o, so the
// mark reads twice rather than once. Ring width is locked to the cap height.
func stacked(wordFill: String, ringFill: String) -> String {
    let capH = CTFontGetCapHeight(font)
    let gap = capH * 0.42
    let fullLine = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [
        .font: font, .kern: tracking, .ligature: 1,
    ]))
    var fullPlaced: [PlacedGlyph] = []
    for run in CTLineGetGlyphRuns(fullLine) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { continue }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        let attrs = CTRunGetAttributes(run) as! [CFString: Any]
        let runFont = (attrs[kCTFontAttributeName] as! CTFont)
        for i in 0..<count {
            fullPlaced.append(PlacedGlyph(glyph: glyphs[i], position: positions[i], font: runFont))
        }
    }
    var wordBounds = CGRect.null
    for g in fullPlaced {
        var glyph = g.glyph
        let b = CTFontGetBoundingRectsForGlyphs(g.font, .horizontal, &glyph, nil, 1)
        wordBounds = wordBounds.union(b.offsetBy(dx: g.position.x, dy: g.position.y))
    }
    let paths = fullPlaced.map(svgPath(for:)).joined()

    let markOuterR = capH / 2
    let markStroke = markOuterR * 2 * ringWeightPct / 100
    let markR = markOuterR - markStroke / 2
    let markCentre = CGPoint(x: wordBounds.midX, y: wordBounds.maxY + gap + markOuterR)

    var box = wordBounds.union(CGRect(x: markCentre.x - markOuterR, y: markCentre.y - markOuterR,
                                      width: markOuterR * 2, height: markOuterR * 2))
    let p = markOuterR * 2
    box = box.insetBy(dx: -p, dy: -p)
    let t = "translate(\(f(-box.minX)) \(f(box.maxY))) scale(1 -1)"

    return """
    \(provenance)
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(f(box.width)) \(f(box.height))" \
    width="\(f(box.width))" height="\(f(box.height))" role="img" aria-label="Cheerio">
      <title>Cheerio</title>
      <g transform="\(t)">
        <circle cx="\(f(markCentre.x))" cy="\(f(markCentre.y))" r="\(f(markR))" \
    fill="none" stroke="\(ringFill)" stroke-width="\(f(markStroke))"/>
        <path fill="\(wordFill)" fill-rule="nonzero" d="\(paths)"/>
      </g>
    </svg>

    """
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func write(_ contents: String, _ name: String) throws {
    try contents.write(to: outDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    print("wrote \(outDir.path)/\(name)")
}

try write(horizontal(wordFill: navy, ringFill: copper), "cheerio-lockup.svg")
try write(horizontal(wordFill: warmWhite, ringFill: copperLight), "cheerio-lockup-reversed.svg")
try write(horizontal(wordFill: "currentColor", ringFill: "currentColor"), "cheerio-lockup-mono.svg")
try write(stacked(wordFill: navy, ringFill: copper), "cheerio-lockup-stacked.svg")

// MARK: - Social card

// GitHub renders the repository card at 1280x640 and crops nothing, so the
// lockup is centred with the clear-space rule doing the framing.
func renderSocialCard(pixels: CGSize) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    let bg = CGGradient(colorsSpace: space,
                        colors: [srgb(0x1E2B3F), srgb(0x35496B)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: pixels.width, y: pixels.height), options: [])

    // Scale so the lockup, clear space included, occupies 62% of the width.
    let scale = (pixels.width * 0.62) / boxW
    ctx.saveGState()
    ctx.translateBy(x: (pixels.width - boxW * scale) / 2,
                    y: (pixels.height - boxH * scale) / 2)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: pad - inkBounds.minX, y: pad - inkBounds.minY)

    ctx.setFillColor(srgb(0xFAFAF9))
    for g in placed {
        var glyph = g.glyph
        var tf = CGAffineTransform(translationX: g.position.x, y: g.position.y)
        if let p = CTFontCreatePathForGlyph(g.font, glyph, &tf) {
            ctx.addPath(p)
        }
        _ = glyph
    }
    ctx.fillPath()

    ctx.setStrokeColor(srgb(0xD49E6C))
    ctx.setLineWidth(ringStroke)
    ctx.strokeEllipse(in: CGRect(x: ringCentre.x - ringCentrelineR,
                                 y: ringCentre.y - ringCentrelineR,
                                 width: ringCentrelineR * 2, height: ringCentrelineR * 2))
    ctx.restoreGState()

    return ctx.makeImage()!
}

let cardDir = URL(fileURLWithPath: "docs")
try FileManager.default.createDirectory(at: cardDir, withIntermediateDirectories: true)
let cardURL = cardDir.appendingPathComponent("social-card.png")
let dest = CGImageDestinationCreateWithURL(cardURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, renderSocialCard(pixels: CGSize(width: 1280, height: 640)), nil)
guard CGImageDestinationFinalize(dest) else { fatalError("failed to write social-card.png") }
print("wrote \(cardURL.path) (1280x640)")

// MARK: - Geometry receipt

print("""

geometry, on the 100-unit em grid
  ink              \(f(inkBounds.width)) x \(f(inkBounds.height))
  ring centre      \(f(ringCentre.x)), \(f(ringCentre.y))
  ring outer dia   \(f(ringOuterR * 2))
  ring stroke      \(f(ringStroke))  (\(f(ringWeightPct))% of outer — the icon's ratio)
  clear space      \(f(pad)) on every side
  viewBox          \(f(boxW)) x \(f(boxH))
""")
