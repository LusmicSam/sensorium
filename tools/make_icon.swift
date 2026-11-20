// Draws the Sensorium app icon at 1024x1024 and writes Resources/AppIcon.icns.
// Run from the project root:  swift tools/make_icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: the body is 824 pt with ~185 pt corners, centred with a 100 pt margin.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// soft drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(shape)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// background gradient: deep indigo -> teal
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(red: 0.10, green: 0.09, blue: 0.28, alpha: 1).cgColor,
                             NSColor(red: 0.05, green: 0.38, blue: 0.47, alpha: 1).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 1024, y: 100), options: [])

// trackpad outline
let pad = CGRect(x: 212, y: 300, width: 600, height: 400)
ctx.addPath(CGPath(roundedRect: pad, cornerWidth: 46, cornerHeight: 46, transform: nil))
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
ctx.setLineWidth(10)
ctx.strokePath()

// touch point with pressure rings (warm, fading outward)
let touch = CGPoint(x: 430, y: 520)
for (i, r) in [150.0, 108.0, 70.0].enumerated() {
    let a = 0.22 + Double(i) * 0.22
    ctx.setStrokeColor(NSColor(red: 1.0, green: 0.62, blue: 0.20, alpha: a).cgColor)
    ctx.setLineWidth(14)
    ctx.strokeEllipse(in: CGRect(x: touch.x - r, y: touch.y - r, width: 2 * r, height: 2 * r))
}
let dot = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                     colors: [NSColor(red: 1.0, green: 0.85, blue: 0.45, alpha: 1).cgColor,
                              NSColor(red: 1.0, green: 0.45, blue: 0.15, alpha: 1).cgColor] as CFArray,
                     locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: touch.x - 44, y: touch.y - 44, width: 88, height: 88))
ctx.clip()
ctx.drawRadialGradient(dot, startCenter: touch, startRadius: 0, endCenter: touch, endRadius: 44, options: [])
ctx.restoreGState()

// sensor waveform across the pad
let wave = CGMutablePath()
let baseY: CGFloat = 520
let pts: [(CGFloat, CGFloat)] = [(212, 0), (520, 0), (560, 60), (600, -120), (640, 150), (680, -40), (712, 0), (812, 0)]
wave.move(to: CGPoint(x: pts[0].0, y: baseY + pts[0].1))
for p in pts.dropFirst() { wave.addLine(to: CGPoint(x: p.0, y: baseY + p.1)) }
ctx.addPath(wave)
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(22)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

// subtle top highlight
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 600), options: [])
ctx.restoreGState()
image.unlockFocus()

// write the iconset and convert with iconutil
let fm = FileManager.default
let set = "/tmp/sensorium-AppIcon.iconset"
try? fm.removeItem(atPath: set)
try! fm.createDirectory(atPath: set, withIntermediateDirectories: true)
let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current!.imageInterpolation = .high
        NSGraphicsContext.current!.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/\(name)"))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
try! fm.copyItem(atPath: "\(set)/icon_512x512@2x.png", toPath: "/tmp/sensorium-icon-preview.png")
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
