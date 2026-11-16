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
        let ink = NSColor.black.withAlphaComponent(state == .offline ? 0.4 : 1)
        ink.set()
        // Two strands (two links) twist together into one cable, like plied yarn.
        for mirror in [false, true] {
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: mirror ? 18 - x : x, y: y) }
            let strand = NSBezierPath()
            strand.move(to: p(9, 6.4))
            strand.curve(to: p(12.4, 11.6), controlPoint1: p(9, 8.8), controlPoint2: p(12.6, 9.4))
            strand.curve(to: p(5.2, 17), controlPoint1: p(12.2, 14.2), controlPoint2: p(5.4, 14.4))
            strand.lineWidth = 1.6
            strand.lineCapStyle = .round
            // The second strand fades when only one link is in use.
            (mirror && state != .combining ? ink.withAlphaComponent(state == .offline ? 0.25 : 0.55) : ink).set()
            strand.stroke()
        }
        ink.set()
        // USB-C plug: filled when the Mac is on the cable, outlined otherwise.
        let plug = NSBezierPath(roundedRect: NSRect(x: 6.1, y: 0.7, width: 5.8, height: 5.0), xRadius: 1.8, yRadius: 1.8)
        if state == .cable || state == .combining {
            plug.fill()
        } else {
            plug.lineWidth = 1.2
            plug.stroke()
        }
    }
}
