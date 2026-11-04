#!/usr/bin/env swift
// Zeichnet das App-Icon und schreibt alle Größen in AppVolume/Assets.xcassets/AppIcon.appiconset.
// Aufruf aus dem Projektordner:  swift Scripts/make-icon.swift
import AppKit

let outDir = URL(fileURLWithPath: "AppVolume/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Zeichnet das Icon in ein 1024×1024-Koordinatensystem (Ursprung unten links).
func drawIcon(in ctx: CGContext) {
    // Raster nach Apple-Vorgabe: 824 pt Fläche mit 100 pt Rand.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x3A2B9E))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [color(0x7B6CFF), color(0x4A33C8), color(0x2B1B7A)] as CFArray,
                                locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 360, y: 900), endRadius: 620, options: [])

    // Drei Schieberegler auf unterschiedlichen Pegeln
    let trackBottom: CGFloat = 250, trackTop: CGFloat = 774
    let trackWidth: CGFloat = 46, knobRadius: CGFloat = 64
    let sliders: [(x: CGFloat, level: CGFloat, tint: UInt32)] = [
        (322, 0.38, 0x7FE3FF), (512, 0.80, 0xD4CCFF), (702, 0.56, 0xFFB86B),
    ]
    for slider in sliders {
        let track = CGRect(x: slider.x - trackWidth / 2, y: trackBottom, width: trackWidth, height: trackTop - trackBottom)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: trackWidth / 2, cornerHeight: trackWidth / 2, transform: nil))
        ctx.setFillColor(color(0xFFFFFF, 0.18))
        ctx.fillPath()

        let knobY = trackBottom + (trackTop - trackBottom) * slider.level
        let filled = CGRect(x: track.minX, y: trackBottom, width: trackWidth, height: knobY - trackBottom)
        ctx.addPath(CGPath(roundedRect: filled, cornerWidth: trackWidth / 2, cornerHeight: trackWidth / 2, transform: nil))
        ctx.setFillColor(color(slider.tint, 0.95))
        ctx.fillPath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.35))
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillEllipse(in: CGRect(x: slider.x - knobRadius, y: knobY - knobRadius,
                                   width: knobRadius * 2, height: knobRadius * 2))
        ctx.restoreGState()
        ctx.setFillColor(color(slider.tint))
        ctx.fillEllipse(in: CGRect(x: slider.x - 22, y: knobY - 22, width: 44, height: 44))
    }
    ctx.restoreGState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: points * scale).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(
    to: outDir.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Icon geschrieben nach \(outDir.path)")
