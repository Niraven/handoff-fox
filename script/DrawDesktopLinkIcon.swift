import AppKit

let header = CommandLine.arguments.contains("--header")
let size = header ? 24 : 512
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}

// The fox's own palette, so the icon and the sprites in the panel agree.
let fur = color(0xE87B46)
let ear = color(0x8E3B46)
let cream = color(0xFFDEA6)
let ink = color(0x2A1720)

if !header {
    let squircle = NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 472, height: 472),
                                xRadius: 106, yRadius: 106)
    // Warm charcoal rather than the old violet, lit from the top left.
    NSGradient(colors: [color(0x40271F), color(0x1A1010)])!.draw(in: squircle, angle: -68)
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), .clear])!
        .draw(in: NSRect(x: 20, y: 300, width: 472, height: 192), angle: -90)
    NSGradient(colors: [.clear, NSColor.black.withAlphaComponent(0.22)])!
        .draw(in: NSRect(x: 20, y: 20, width: 472, height: 150), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Rim light, drawn twice so it survives the shrink to 16 pt in the Dock.
    color(0xFFFFFF, 0.14).setStroke()
    let rim = NSBezierPath(roundedRect: NSRect(x: 21.5, y: 21.5, width: 469, height: 469),
                           xRadius: 105, yRadius: 105)
    rim.lineWidth = 1.5
    rim.stroke()
}

// An original curled desk fox. Each cell stays crisp when the widget shrinks.
let fox = [
    "...a........a.........",
    "...aa......aa.........",
    "...apa....apa.........",
    "...appa..appa.........",
    "...aaaaaaaaaa.........",
    "..aaaaaaaaaaaa........",
    "..aaaoaaaaoaaa........",
    "..aawwaaaawwaa........",
    "...wwwwowwww..........",
    "....wwwwwww...........",
    "......aaaaaa..........",
    ".....aaaaaaaaa.....c..",
    "....aaaaaaaaaaa...ca..",
    "....aaaaaaaaaaaa.caa..",
    "....aaaaaaaaaaaaaaaa..",
    ".....aaaaaaaaaaaaaa...",
    "......aaaaaaaaaaaa....",
    ".......aaaaaaaaa......",
]
let palette: [Character: NSColor] = ["a": fur, "p": ear, "w": cream, "o": ink, "c": cream]

// Centre the grid in the canvas so the fox sits on the optical centre, not the middle.
let pixel = header ? CGFloat(1) : CGFloat(19)
let originX = header ? CGFloat(1) : (CGFloat(size) - 22 * pixel) / 2
let originY = header ? CGFloat(3) : (CGFloat(size) - CGFloat(fox.count) * pixel) / 2 - 6

for (row, line) in fox.enumerated() {
    for (column, cell) in line.enumerated() {
        guard let pigment = palette[cell] else { continue }
        // A template header glyph is alpha-only; keep the eyes as holes so the shape reads.
        if header && cell == "o" { continue }
        (header ? color(0x000000) : pigment).setFill()
        NSBezierPath(rect: NSRect(x: originX + CGFloat(column) * pixel,
                                  y: originY + CGFloat(fox.count - 1 - row) * pixel,
                                  width: pixel, height: pixel)).fill()
    }
}

if !header {
    // The handoff spark: two cream bars, offset from the tail.
    cream.setFill()
    NSBezierPath(rect: NSRect(x: 396, y: 356, width: 16, height: 16)).fill()
    NSBezierPath(rect: NSRect(x: 380, y: 340, width: 48, height: 16)).fill()
    NSBezierPath(rect: NSRect(x: 396, y: 324, width: 16, height: 16)).fill()
}

try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
