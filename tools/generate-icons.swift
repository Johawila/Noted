// Generates Noted's app icon and menu bar glyph straight into Assets.xcassets.
//
// The icon is code rather than a binary someone dropped in once: tweak a number here, re-run,
// and every size regenerates consistently. Run it with:
//
//     swift tools/generate-icons.swift
//
// This file deliberately lives outside Noted/ — that folder is a file-system-synchronized
// group, so anything .swift inside it gets compiled into the app and would collide with @main.
import AppKit
import Foundation

// MARK: - Palette

// Candidate A "Caret": a cursor waiting for input, which is what ⌘⇧Space actually gives you.
let bgTop = NSColor(srgbRed: 0x1B / 255, green: 0x1E / 255, blue: 0x26 / 255, alpha: 1)
let bgBottom = NSColor(srgbRed: 0x0E / 255, green: 0x10 / 255, blue: 0x14 / 255, alpha: 1)
let lineNear = NSColor(srgbRed: 0x3A / 255, green: 0x3F / 255, blue: 0x4A / 255, alpha: 1)
let lineFar = NSColor(srgbRed: 0x2C / 255, green: 0x31 / 255, blue: 0x3A / 255, alpha: 1)
let accent = NSColor(srgbRed: 0xC8 / 255, green: 0xFF / 255, blue: 0x4D / 255, alpha: 1)

// MARK: - Geometry

// Apple's macOS icon grid: the rounded rect covers 824 of a 1024 canvas, corner radius 185.4.
// Everything else is expressed as a fraction of that square so it scales exactly.
let squircleRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat = 185.4 / 824.0

struct Element {
    let x: CGFloat, yFromTop: CGFloat, w: CGFloat, h: CGFloat, color: NSColor
}

let elements = [
    Element(x: 0.200, yFromTop: 0.300, w: 0.414, h: 0.064, color: lineNear),
    Element(x: 0.200, yFromTop: 0.443, w: 0.271, h: 0.064, color: lineFar),
    Element(x: 0.671, yFromTop: 0.229, w: 0.086, h: 0.357, color: accent),
]

// MARK: - Drawing

func rep(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    return rep
}

func render(_ pixels: Int, _ body: (CGFloat) -> Void) -> NSBitmapImageRep {
    let bitmap = rep(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    body(CGFloat(pixels))
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func appIcon(_ pixels: Int) -> NSBitmapImageRep {
    render(pixels) { canvas in
        let side = canvas * squircleRatio
        let origin = (canvas - side) / 2
        let radius = side * cornerRatio
        let box = NSRect(x: origin, y: origin, width: side, height: side)
        let squircle = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

        NSGradient(starting: bgTop, ending: bgBottom)?.draw(in: squircle, angle: -90)

        for e in elements {
            // Cocoa's origin is bottom-left, so flip the top-down fractions.
            let r = NSRect(
                x: origin + e.x * side,
                y: origin + (1 - e.yFromTop - e.h) * side,
                width: e.w * side, height: e.h * side
            )
            e.color.setFill()
            let cap = min(r.width, r.height) / 2
            NSBezierPath(roundedRect: r, xRadius: cap, yRadius: cap).fill()
        }
    }
}

// The menu bar gets a template mask — macOS throws away colour, so this is pure black + alpha,
// drawn on its own 16pt grid rather than shrunk from the app icon.
func menuBarGlyph(_ pixels: Int) -> NSBitmapImageRep {
    render(pixels) { canvas in
        let k = canvas / 16
        NSColor.black.setFill()
        let bars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (2, 5.0, 8, 2),      // top line
            (2, 9.5, 5, 2),      // shorter line below
            (12, 2.5, 2.5, 11),  // the caret
        ]
        for (x, yFromTop, w, h) in bars {
            let r = NSRect(x: x * k, y: (16 - yFromTop - h) * k, width: w * k, height: h * k)
            let cap = min(r.width, r.height) / 2
            NSBezierPath(roundedRect: r, xRadius: cap, yRadius: cap).fill()
        }
    }
}

// MARK: - Output

let assets = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Noted/Assets.xcassets")

func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed for \(url.lastPathComponent)")
    }
    try png.write(to: url)
}

// (point size, scale) pairs macOS asks for; pixels = points * scale.
let appIconSizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                  (256, 1), (256, 2), (512, 1), (512, 2)]

let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

var iconEntries: [String] = []
for (points, scale) in appIconSizes {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try write(appIcon(points * scale), to: iconSet.appendingPathComponent(name))
    iconEntries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(points)x\(points)"
        }
    """)
}
try """
{
  "images" : [
\(iconEntries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""".write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

let glyphSet = assets.appendingPathComponent("MenuBarGlyph.imageset")
try FileManager.default.createDirectory(at: glyphSet, withIntermediateDirectories: true)
try write(menuBarGlyph(16), to: glyphSet.appendingPathComponent("glyph.png"))
try write(menuBarGlyph(32), to: glyphSet.appendingPathComponent("glyph@2x.png"))
try """
{
  "images" : [
    {
      "filename" : "glyph.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "glyph@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
""".write(to: glyphSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

print("Wrote \(appIconSizes.count) app icon sizes + menu bar glyph to \(assets.path)")
