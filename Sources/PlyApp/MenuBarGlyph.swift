import AppKit

/// Ply's own menu bar icon: the app icon's cable curling up into Wi-Fi arcs, drawn as an
/// 18 pt template image so macOS tints it like any other menu bar icon.
enum MenuBarGlyph {
    enum State { case cable, wifi, combining, offline }

    static func image(_ state: State) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw(state)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Ply"
        return img
    }

    static func draw(_ state: State) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setAlpha(state == .offline ? 0.4 : 1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { ctx.endTransparencyLayer() }
        let ink = NSColor.black
        // Phone outline; the screen fills in while the Mac is on the iPhone's cable.
        let phone = NSBezierPath(roundedRect: NSRect(x: 2.2, y: 1.6, width: 8.6, height: 15), xRadius: 2.4, yRadius: 2.4)
        ink.set()
        if state == .cable || state == .combining {
            phone.fill()
        } else {
            phone.lineWidth = 1.5
            phone.stroke()
            let ear = NSBezierPath()
            ear.move(to: NSPoint(x: 5.4, y: 14.6)); ear.line(to: NSPoint(x: 7.6, y: 14.6))
            ear.lineWidth = 1.2; ear.lineCapStyle = .round; ear.stroke()
        }
        // Two chain links over the bottom right corner, cut out of the phone.
        let links = linkPaths()
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        for l in links { l.lineWidth = 4.4; l.stroke() }
        ctx.restoreGState()
        ink.set()
        for l in links { l.lineWidth = 1.6; l.stroke() }
        if state == .combining {
            NSBezierPath(ovalIn: NSRect(x: 13.6, y: 13.2, width: 4, height: 4)).fill()
        }
    }

    private static func linkPaths() -> [NSBezierPath] {
        [(-1.0, 1.0), (1.0, -1.0)].map { (dx: CGFloat, dy: CGFloat) in
            let p = NSBezierPath(roundedRect: NSRect(x: -3.3, y: -1.6, width: 6.6, height: 3.2), xRadius: 1.6, yRadius: 1.6)
            var t = AffineTransform(translationByX: 12.9 + dx * 2.3, byY: 5.3 + dy * 2.3)
            t.rotate(byDegrees: -45)
            p.transform(using: t)
            return p
        }
    }
}
