// Draws Ply's app icon: two strands (Wi-Fi + iPhone) merging into one.
// Usage: swift scripts/make-icon.swift <out.iconset dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Ply.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    // macOS icon grid: 824pt rounded square centered in 1024.
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: rect, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.62, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.13, green: 0.38, blue: 0.95, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // Two strands merging into one.
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(74 * s)
    let joinY = 470 * s
    let left = CGMutablePath()
    left.move(to: CGPoint(x: 330 * s, y: 760 * s))
    left.addCurve(to: CGPoint(x: 512 * s, y: joinY), control1: CGPoint(x: 330 * s, y: 600 * s), control2: CGPoint(x: 512 * s, y: 600 * s))
    let right = CGMutablePath()
    right.move(to: CGPoint(x: 694 * s, y: 760 * s))
    right.addCurve(to: CGPoint(x: 512 * s, y: joinY), control1: CGPoint(x: 694 * s, y: 600 * s), control2: CGPoint(x: 512 * s, y: 600 * s))
    ctx.addPath(left); ctx.strokePath()
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.78).cgColor)
    ctx.addPath(right); ctx.strokePath()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(96 * s)
    ctx.move(to: CGPoint(x: 512 * s, y: joinY)); ctx.addLine(to: CGPoint(x: 512 * s, y: 250 * s)); ctx.strokePath()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(size: px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
print("wrote \(out.path)")
