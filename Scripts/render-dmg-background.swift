#!/usr/bin/env swift
// Renders the disk-image window background — deep navy, two icon wells, a
// copper arrow between them — as background.png (1x) and background@2x.png.
//
// Generated, not drawn, for the same reason as the app icon: the geometry has
// to agree with the icon coordinates Finder is told to use, and two numbers
// kept in sync by hand drift. `Scripts/make-dmg.sh` owns both halves — it runs
// this script and then passes matching coordinates to dmgbuild — so the arrow
// lands between the icons rather than near them.
//
// Output is NOT committed. It is built in CI alongside the DMG; nothing else
// in the repo consumes it.
//
// Run from the repo root:  swift Scripts/render-dmg-background.swift <out-dir>

import AppKit
import UniformTypeIdentifiers

// The window's content size in points. make-dmg.sh uses the same numbers for
// window_rect and derives its icon_locations from ICON_CENTER_Y / the well
// centres below, so changing a value here changes the layout coherently.
let width: CGFloat = 640
let height: CGFloat = 400

// Icon centres, in Finder's coordinate space: origin top-left, y downward.
let leftIconCenter = CGPoint(x: 168, y: 172)
let rightIconCenter = CGPoint(x: 472, y: 172)
let iconSize: CGFloat = 128

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

// site/tokens.css: --ch-navy-500 / --ch-navy-900 / --ch-copper-300 / -700.
let navyTop = srgb(0x35_49_6B)
let navyBottom = srgb(0x1E_2B_3F)
let copperTop = srgb(0xD4_9E_6C)
let copperBottom = srgb(0xA8_70_40)
let wellFill = srgb(0xFF_FF_FF, 0.05)
let wellStroke = srgb(0xFF_FF_FF, 0.10)
let captionColor = srgb(0xD4_9E_6C, 0.85)
let subCaptionColor = srgb(0xFF_FF_FF, 0.45)

/// Finder y (down from the top) → Core Graphics y (up from the bottom).
func flip(_ y: CGFloat) -> CGFloat { height - y }

/// A rounded well marking where an icon lands, sized a little larger than the
/// icon so the icon sits *in* it rather than on it.
func drawWell(_ ctx: CGContext, center: CGPoint) {
    let side = iconSize + 40
    let rect = CGRect(
        x: center.x - side / 2, y: flip(center.y) - side / 2,
        width: side, height: side)
    let path = CGPath(
        roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(wellFill)
    ctx.fillPath()
    ctx.addPath(path)
    ctx.setStrokeColor(wellStroke)
    ctx.setLineWidth(1)
    ctx.strokePath()
}

/// A flat copper arrow spanning the gap between the two wells.
func drawArrow(_ ctx: CGContext) {
    let y = flip(leftIconCenter.y)
    let startX = leftIconCenter.x + (iconSize + 40) / 2 + 22
    let endX = rightIconCenter.x - (iconSize + 40) / 2 - 22
    let head: CGFloat = 18
    let shaft: CGFloat = 5

    ctx.saveGState()
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: startX, y: y - shaft / 2))
    arrow.addLine(to: CGPoint(x: endX - head, y: y - shaft / 2))
    arrow.addLine(to: CGPoint(x: endX - head, y: y - head / 2))
    arrow.addLine(to: CGPoint(x: endX, y: y))
    arrow.addLine(to: CGPoint(x: endX - head, y: y + head / 2))
    arrow.addLine(to: CGPoint(x: endX - head, y: y + shaft / 2))
    arrow.addLine(to: CGPoint(x: startX, y: y + shaft / 2))
    arrow.closeSubpath()
    ctx.addPath(arrow)
    ctx.clip()
    let copper = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [copperBottom, copperTop] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        copper, start: CGPoint(x: startX, y: y), end: CGPoint(x: endX, y: y),
        options: [])
    ctx.restoreGState()
}

/// One line of text, centred, at a Finder-space baseline.
func drawCentered(
    _ ctx: CGContext, _ text: String, size: CGFloat, weight: NSFont.Weight,
    color: CGColor, baselineY: CGFloat
) {
    let attributed = NSAttributedString(
        string: text,
        attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(cgColor: color)!,
            .kern: 0.2,
        ])
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(
        x: (width - bounds.width) / 2 - bounds.minX, y: flip(baselineY))
    CTLineDraw(line, ctx)
}

/// The instruction the window exists to give, plus one quieter line for people
/// who already have the app. Both sit below the icons and their Finder labels,
/// which land at roughly y = 236…258.
///
/// The second line exists because of a real dead end: someone who already runs
/// Cheerio downloads again, drags, and Finder refuses with "Cheerio can't be
/// replaced because it's open" — a message that suggests no way forward. It
/// says the useful thing instead: they never needed to download at all. Kept
/// dim and small; the drag is still the primary instruction.
func drawCaptions(_ ctx: CGContext) {
    drawCentered(
        ctx, "Drag Cheerio to your Applications folder",
        size: 15, weight: .medium, color: captionColor, baselineY: 306)
    drawCentered(
        ctx, "Already installed? Cheerio updates itself.",
        size: 12, weight: .regular, color: subCaptionColor, baselineY: 332)
}

func render(scale: CGFloat) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: Int(width * scale), height: Int(height * scale),
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)

    // Vertical navy gradient, light at the top (CG origin is bottom-left).
    let bg = CGGradient(
        colorsSpace: space, colors: [navyBottom, navyTop] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        bg, start: CGPoint(x: width / 2, y: 0),
        end: CGPoint(x: width / 2, y: height), options: [])

    drawWell(ctx, center: leftIconCenter)
    drawWell(ctx, center: rightIconCenter)
    drawArrow(ctx)
    drawCaptions(ctx)

    return ctx.makeImage()!
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: swift Scripts/render-dmg-background.swift <out-dir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for (name, scale) in [("background.png", CGFloat(1)), ("background@2x.png", CGFloat(2))] {
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    let image = render(scale: scale)
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("failed to write \(name)") }
    print("wrote \(name) (\(image.width)x\(image.height))")
}
