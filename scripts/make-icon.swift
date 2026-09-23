// Renders app/Resources/AppIcon.icns: a green rounded square with a white
// caption bubble. Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
    let box = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: box, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.55, green: 0.86, blue: 0.36, alpha: 1),
               ending: NSColor(red: 0.10, green: 0.55, blue: 0.36, alpha: 1))!.draw(in: shape, angle: -90)
    // Drawn by hand: Apple's licence doesn't allow SF Symbols in app icons.
    let bubble = NSBezierPath(roundedRect: NSRect(x: 262 * s, y: 372 * s, width: 500 * s, height: 370 * s), xRadius: 100 * s, yRadius: 100 * s)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 380 * s, y: 400 * s))
    tail.line(to: NSPoint(x: 380 * s, y: 282 * s))
    tail.line(to: NSPoint(x: 510 * s, y: 400 * s))
    tail.close()
    NSColor.white.setFill()
    bubble.fill()
    tail.fill()
    // Two lines of caption text.
    NSColor(red: 0.20, green: 0.65, blue: 0.38, alpha: 1).setFill()
    for (x, y, w) in [(342, 580, 120), (482, 580, 200), (342, 500, 70), (432, 500, 140), (592, 500, 90)] as [(CGFloat, CGFloat, CGFloat)] {
        NSBezierPath(roundedRect: NSRect(x: x * s, y: y * s, width: w * s, height: 36 * s), xRadius: 18 * s, yRadius: 18 * s).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try! render(points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try! render(points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let out = root.appending(path: "app/Resources/AppIcon.icns")
try! FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! iconutil.run()
iconutil.waitUntilExit()
print(out.path)
