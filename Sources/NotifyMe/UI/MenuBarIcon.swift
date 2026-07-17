import AppKit

/// The menu-bar icon: the app's own mark — a ring with a gap, and the dot that came away from it.
///
/// Drawn as a **template image**, which means macOS throws away whatever colour is drawn and keeps only
/// the alpha, then tints the result itself. That is not a limitation being worked around; it is the only
/// way a menu-bar icon can be correct. A template inverts for a light or dark menu bar, dims when the
/// system wants it dim, and goes white when the menu is open. A hand-coloured icon does none of those,
/// and looks broken in half the states a menu bar can be in.
///
/// So the dot is apricot in the app icon and monochrome here. Same mark, different medium.
enum MenuBarIcon {

    /// Vector-drawn at exactly the size it is used at. The whole figure is a gap and a dot, and both are
    /// the first things to turn to mush when a large bitmap is resampled down to 18 points.
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let outer = size * 0.82
            let stroke = outer * 0.16
            let radius = (outer - stroke) / 2
            let centre = NSPoint(x: rect.midX, y: rect.midY)

            // Colour is irrelevant in a template — only coverage survives. Black is just the convention.
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Anticlockwise from 130° round through left, bottom, right, stopping at 88° — just shy of
            // top dead centre, leaving the gap.
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: centre,
                radius: radius,
                startAngle: 130,
                endAngle: 88 + 360,
                clockwise: false
            )
            arc.lineWidth = stroke
            arc.lineCapStyle = .round
            arc.stroke()

            // The dot: at the gap's midpoint, on the ring's own centreline, at the weight of the stroke
            // it left — so it reads as a piece of the ring that came away, not a bead parked beside it.
            let midpoint = (88.0 + 130.0) / 2 * .pi / 180
            let dot = stroke * 0.95
            let point = NSPoint(
                x: centre.x + cos(midpoint) * radius,
                y: centre.y + sin(midpoint) * radius
            )
            NSBezierPath(ovalIn: NSRect(
                x: point.x - dot / 2,
                y: point.y - dot / 2,
                width: dot,
                height: dot
            )).fill()

            return true
        }
        image.isTemplate = true
        return image
    }
}
