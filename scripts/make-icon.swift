// Draws Earshot's app icon and writes it as an .icns.
//
//   swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon AppIcon.icns
//
// Drawn rather than shipped as artwork so the source is reviewable, and drawn at every size rather
// than scaled from 1024 so the strokes stay crisp at 16 px. Plain shapes on purpose: Apple's SF
// Symbols licence does not allow them in app icons.

import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

/// Coordinates are on Apple's 1024 icon grid, origin bottom left.
func draw(_ c: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Tile with a soft drop shadow, as macOS icons have.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    c.addPath(tilePath)
    c.setFillColor(CGColor(red: 0.09, green: 0.11, blue: 0.20, alpha: 1))
    c.fillPath()
    c.restoreGState()

    // Navy to near-black, lighter at the top.
    c.saveGState()
    c.addPath(tilePath)
    c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(red: 0.20, green: 0.27, blue: 0.48, alpha: 1),
        CGColor(red: 0.06, green: 0.08, blue: 0.15, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.restoreGState()

    let white = CGColor(red: 0.96, green: 0.97, blue: 1, alpha: 1)

    // Headband.
    c.setStrokeColor(white)
    c.setLineWidth(56)
    c.setLineCap(.round)
    c.addArc(center: CGPoint(x: 512, y: 560), radius: 245, startAngle: .pi, endAngle: 0, clockwise: true)
    c.strokePath()

    // Ear cups.
    c.setFillColor(white)
    for x in [267.0, 757.0] {
        let cup = CGRect(x: x - 72, y: 330, width: 144, height: 270)
        c.addPath(CGPath(roundedRect: cup, cornerWidth: 64, cornerHeight: 64, transform: nil))
    }
    c.fillPath()

    // Battery between the cups, three quarters full.
    let body = CGRect(x: 402, y: 382, width: 204, height: 100)
    c.setLineWidth(16)
    c.addPath(CGPath(roundedRect: body, cornerWidth: 26, cornerHeight: 26, transform: nil))
    c.strokePath()
    c.addPath(CGPath(roundedRect: CGRect(x: 614, y: 412, width: 18, height: 40), cornerWidth: 6, cornerHeight: 6, transform: nil))
    c.fillPath()
    c.setFillColor(CGColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1))
    let fill = body.insetBy(dx: 22, dy: 22)
    c.addPath(CGPath(roundedRect: CGRect(x: fill.minX, y: fill.minY, width: fill.width * 0.75, height: fill.height),
                     cornerWidth: 10, cornerHeight: 10, transform: nil))
    c.fillPath()
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("earshot-\(getpid()).iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                     ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(context)
    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
