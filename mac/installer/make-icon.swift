#!/usr/bin/env swift
// Generate AppIcon.icns for XVC Live Mic.
//
// A tasteful icon in KTH's visual identity — KTH blue squircle, white microphone, "XVC"
// wordmark. It does NOT embed KTH's actual trademarked logo (we don't have the asset and
// shouldn't fabricate it); drop the real mark in here if brand approval is obtained.
//
//   swift make-icon.swift            -> installer/AppIcon.icns
import AppKit

let KTHBlue = NSColor(srgbRed: 0.0, green: 0.28, blue: 0.57, alpha: 1)      // ~#004791
let KTHBlueLo = NSColor(srgbRed: 0.0, green: 0.20, blue: 0.42, alpha: 1)

func renderIcon(size S: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle background with a vertical KTH-blue gradient.
    let inset = S * 0.06
    let rect = NSRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
    let radius = (S - 2*inset) * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()
    let grad = NSGradient(colors: [KTHBlue, KTHBlueLo])!
    grad.draw(in: rect, angle: -90)

    // Microphone glyph (SF Symbol), white, centered in the upper portion.
    let cfg = NSImage.SymbolConfiguration(pointSize: S * 0.42, weight: .semibold)
    if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: mic.size)
        tinted.lockFocus()
        NSColor.white.set()
        let r = NSRect(origin: .zero, size: mic.size)
        mic.draw(in: r)
        r.fill(using: .sourceAtop)
        tinted.unlockFocus()
        let mw = mic.size.width, mh = mic.size.height
        tinted.draw(in: NSRect(x: (S - mw)/2, y: S*0.40, width: mw, height: mh))
    }

    // "XVC" wordmark below the mic.
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let font = NSFont.systemFont(ofSize: S * 0.18, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.white, .paragraphStyle: para,
        .kern: S * 0.01,
    ]
    let text = "XVC" as NSString
    let th = font.ascender - font.descender
    text.draw(in: NSRect(x: 0, y: S*0.20, width: S, height: th), withAttributes: attrs)

    _ = ctx
    img.unlockFocus()
    return img
}

func png(_ image: NSImage, _ px: Int) -> Data {
    let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
    renderIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return bmp.representation(using: .png, properties: [:])!
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Standard iconset sizes (1x and 2x).
let specs: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in specs {
    try! png(NSImage(), px).write(to: iconset.appendingPathComponent("\(name).png"))
}

// iconutil turns the iconset into a .icns.
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote \(here.appendingPathComponent("AppIcon.icns").path)")
