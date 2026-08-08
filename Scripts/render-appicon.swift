#!/usr/bin/env swift
// Renders the Cheerio app icon — a copper ring on deep navy — into
// Cheerio/Resources/Assets.xcassets/AppIcon.appiconset/.
//
// The art is full-bleed square: macOS 26 masks every app icon into its own
// squircle, so the PNGs must not bake in a shape or margins. Geometry is
// defined on a 100-unit grid and scaled; small sizes thicken the ring and
// drop the hairline edges (optical correction, not proportional scaling).
//
// Run from the repo root:  swift Scripts/render-appicon.swift

import AppKit
import UniformTypeIdentifiers

struct RingSpec {
    let radius: CGFloat      // ring centerline radius, 100-unit grid
    let stroke: CGFloat      // ring thickness, 100-unit grid
    let hairlines: Bool      // 1-unit ink edges inside/outside the ring
}

// Per-pixel-size optical corrections.
func spec(forPixels px: Int) -> RingSpec {
    switch px {
    case ..<24:   return RingSpec(radius: 27.0, stroke: 21.0, hairlines: false)
    case ..<48:   return RingSpec(radius: 27.0, stroke: 19.5, hairlines: false)
    case ..<96:   return RingSpec(radius: 26.5, stroke: 18.0, hairlines: false)
    case ..<192:  return RingSpec(radius: 26.0, stroke: 17.5, hairlines: true)
    default:      return RingSpec(radius: 26.0, stroke: 17.0, hairlines: true)
    }
}

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let navyTop = srgb(0x35496B), navyBottom = srgb(0x1E2B3F)
let copperTop = srgb(0xD49E6C), copperBottom = srgb(0xA87040)
let inkEdge = 0x1E2B3F as UInt32

func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels,
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(pixels) / 100
    ctx.scaleBy(x: s, y: s)

    let ring = spec(forPixels: pixels)
    let c = CGPoint(x: 50, y: 50)

    // Background: vertical navy gradient (CG origin is bottom-left, so the
    // light stop goes at y=100).
    let bg = CGGradient(colorsSpace: space,
                        colors: [navyBottom, navyTop] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 50, y: 0),
                           end: CGPoint(x: 50, y: 100), options: [])

    // Ring: copper gradient clipped to the annulus.
    let outerR = ring.radius + ring.stroke / 2
    let innerR = ring.radius - ring.stroke / 2
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - outerR, y: c.y - outerR, width: outerR * 2, height: outerR * 2))
    ctx.addEllipse(in: CGRect(x: c.x - innerR, y: c.y - innerR, width: innerR * 2, height: innerR * 2))
    ctx.clip(using: .evenOdd)
    let copper = CGGradient(colorsSpace: space,
                            colors: [copperBottom, copperTop] as CFArray,
                            locations: [0, 1])!
    ctx.drawLinearGradient(copper, start: CGPoint(x: 50, y: c.y - outerR),
                           end: CGPoint(x: 50, y: c.y + outerR), options: [])
    ctx.restoreGState()

    // Ink edges: faint navy hairlines that seat the ring on large sizes.
    if ring.hairlines {
        ctx.setLineWidth(1)
        ctx.setStrokeColor(srgb(inkEdge, 0.35))
        ctx.strokeEllipse(in: CGRect(x: c.x - outerR, y: c.y - outerR, width: outerR * 2, height: outerR * 2))
        ctx.setStrokeColor(srgb(inkEdge, 0.25))
        ctx.strokeEllipse(in: CGRect(x: c.x - innerR, y: c.y - innerR, width: innerR * 2, height: innerR * 2))
    }

    return ctx.makeImage()!
}

let outDir = URL(fileURLWithPath: "Cheerio/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// (point size, scale) pairs required by a macOS app icon set.
let slots: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                           (256, 1), (256, 2), (512, 1), (512, 2)]

var images: [[String: String]] = []
for (points, scale) in slots {
    let px = points * scale
    let name = scale == 1 ? "icon_\(points).png" : "icon_\(points)@2x.png"
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(pixels: px), nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("failed to write \(name)") }
    images.append(["filename": name, "idiom": "mac",
                   "scale": "\(scale)x", "size": "\(points)x\(points)"])
    print("wrote \(name) (\(px)px)")
}

let contents: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(withJSONObject: contents,
                                      options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote Contents.json")
