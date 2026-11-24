import AppKit

let header = CommandLine.arguments.contains("--header")
let size = header ? 24 : 512
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

func color(_ rgb: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
}

if !header {
    let border = NSBezierPath(roundedRect: NSRect(x: 18, y: 18, width: 476, height: 476),
                              xRadius: 100, yRadius: 100)
    NSGradient(starting: color(0x574675), ending: color(0x231b39))!.draw(in: border, angle: -50)
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
    ".....aaaaaaaaa.....w..",
    "....aaaaaaaaaaa...wa..",
    "....aaaaaaaaaaaa.waa..",
    "....aaaaaaaaaaaaaaaa..",
    ".....aaaaaaaaaaaaaa...",
    "......aaaaaaaaaaaa....",
    ".......aaaaaaaaa......",
]
let palette: [Character: UInt32] = [
    "a": 0xf4ac84, "p": 0xc16d83, "w": 0xffedda, "o": 0x32203f,
]
let pixel: CGFloat = header ? 1 : 18
for (row, line) in fox.enumerated() {
    for (column, cell) in line.enumerated() {
        guard let pigment = palette[cell] else { continue }
        if header && cell == "o" { continue }
        color(header ? 0xf1a176 : pigment).setFill()
        NSBezierPath(rect: NSRect(x: (header ? 0 : 60) + CGFloat(column) * pixel,
            y: (header ? 3 : 86) + CGFloat(fox.count - 1 - row) * pixel, width: pixel, height: pixel)).fill()
    }
}
if !header {
    color(0xc4efdc).setFill()
    NSBezierPath(rect: NSRect(x: 418, y: 378, width: 14, height: 14)).fill()
    NSBezierPath(rect: NSRect(x: 404, y: 364, width: 42, height: 14)).fill()
    NSBezierPath(rect: NSRect(x: 418, y: 350, width: 14, height: 14)).fill()
}
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
