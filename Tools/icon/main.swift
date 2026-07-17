import AppKit

/// Generates `Resources/AppIcon.icns`.
///
/// The mark: a thick ring with a gap at the top, and a detached dot sitting in that gap, on the ring's
/// own centreline. It is the app's alphabet said in one figure — an outlined circle is a session that
/// is working, and the dot is the one that has broken away and wants you.
///
///     swiftc -o /tmp/cticon Tools/icon/main.swift -framework AppKit
///     /tmp/cticon Resources
///
/// Then `iconutil -c icns` (the Makefile does it).

// MARK: - Geometry
//
// A 1024 canvas. Everything below is a fraction of it, so every size renders as vector and nothing is
// upscaled — at 16pt this icon is 16 real pixels, and a resized 1024 would be mush.

/// Apple's icon grid: the rounded body is inset from the canvas, not flush with it. Get this wrong and
/// the icon sits visibly larger than every other icon beside it in Notification Centre.
private let bodyInset: CGFloat = 100.0 / 1024.0
private let bodyRadius: CGFloat = 185.0 / 1024.0

/// The mark, as a fraction of the *body* (not the canvas).
///
/// Generous on purpose. The whole idea of this figure is a gap and a dot, and both are the first
/// things to die at 16pt — so the mark is given the room to survive being small rather than the room
/// to look elegant when it's large.
private let markOuterDiameter: CGFloat = 0.70
private let strokeRatio: CGFloat = 0.14    // stroke ÷ outer diameter

/// Dot diameter ÷ stroke width. **Effectively 1.** The dot is not a decoration parked near the ring —
/// it is a *piece of the ring that has come away*, and it only reads that way if it is the same weight
/// as the stroke it left.
private let dotRatio: CGFloat = 0.95

/// The gap, in degrees. Standard maths angles: 0° = right, 90° = top.
///
/// The arc runs anticlockwise from 130° all the way round — left, bottom, right — and stops at 88°,
/// just shy of top dead centre. The dot sits at the gap's midpoint, on the centreline, so it reads as
/// a piece of the ring that has come away rather than a decoration parked nearby.
private let arcStart: CGFloat = 130
private let arcEnd: CGFloat = 88 + 360

// MARK: - Palette
//
// The icon says what the app says, in the app's own two words.
//
// The **ring is white**: a working session, quiet, self-sufficient, wanting nothing. The **dot is
// apricot** — the app's "needs you" — and it is the one that has come away from the ring. Everything
// else is monochrome, so the single point of colour is the only thing in the figure that is *asking*
// for something. That is the whole product in one mark.
//
// Dark, not white. The previous tile was near-white with a black ring, and macOS's own icon treatment
// put a bevel under the artwork that made it look embossed and about fifteen years old. On near-black
// that shadow is invisible, the white ring reads as light rather than as ink, and the apricot glows.

private let tileTop = NSColor(srgbRed: 0.106, green: 0.106, blue: 0.125, alpha: 1)   // #1B1B20
private let tileBottom = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.055, alpha: 1) // #0B0B0E
private let ringInk = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.976, alpha: 1)   // #F6F6F9
private let dotInk = NSColor(srgbRed: 0.961, green: 0.780, blue: 0.494, alpha: 1)    // #F5C77E — apricot

private func drawIcon(size: CGFloat, in rect: NSRect) {
    let inset = size * bodyInset
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = size * bodyRadius

    // A whisper of a gradient, top-lit. Flat black reads as a hole; this reads as an object.
    let tile = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(starting: tileTop, ending: tileBottom)?.draw(in: tile, angle: -90)

    let outer = body.width * markOuterDiameter
    let stroke = outer * strokeRatio
    let r = (outer - stroke) / 2                 // centreline radius
    let c = NSPoint(x: body.midX, y: body.midY)

    // The ring: working, and quiet about it.
    let arc = NSBezierPath()
    arc.appendArc(
        withCenter: c,
        radius: r,
        startAngle: arcStart,
        endAngle: arcEnd,
        clockwise: false
    )
    arc.lineWidth = stroke
    arc.lineCapStyle = .round
    ringInk.setStroke()
    arc.stroke()

    // The dot: on the ring's own centreline, at the gap's midpoint, and the same weight as the stroke
    // it left — so it reads as a piece of the ring that has come away, not as a bead parked nearby.
    let mid = (arcEnd - 360 + arcStart) / 2 * .pi / 180
    let dot = stroke * dotRatio
    let p = NSPoint(x: c.x + cos(mid) * r, y: c.y + sin(mid) * r)
    dotInk.setFill()
    NSBezierPath(ovalIn: NSRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)).fill()
}

// MARK: - Emit

private func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    // Redraw at every size rather than resampling one big one: the gap and the dot are the whole idea,
    // and at 16pt a downscaled 1024 turns both to porridge.
    drawIcon(size: CGFloat(size), in: NSRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The exact set `iconutil` expects.
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in sizes {
    try! png(size: size).write(to: iconset.appendingPathComponent("\(name).png"))
}
// A standalone 1024 for READMEs and for looking at.
try! png(size: 1024).write(to: out.appendingPathComponent("AppIcon-1024.png"))
print("wrote \(sizes.count) sizes to \(iconset.path)")
