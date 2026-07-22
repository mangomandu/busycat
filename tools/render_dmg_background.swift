import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? ".build/dmg/background.png"
let size = NSSize(width: 660, height: 440)
let canvas = NSRect(origin: .zero, size: size)
let image = NSImage(size: size)

func drawText(
    _ text: String,
    at point: NSPoint,
    font: NSFont,
    color: NSColor,
    tracking: CGFloat = 0
) {
    NSAttributedString(
        string: text,
        attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: tracking,
        ]
    ).draw(at: point)
}

image.lockFocus()

let background = NSColor(calibratedRed: 0.95, green: 0.965, blue: 0.99, alpha: 1)
let header = NSColor(calibratedRed: 0.075, green: 0.094, blue: 0.137, alpha: 1)
let blue = NSColor(calibratedRed: 0.32, green: 0.58, blue: 0.98, alpha: 1)
let bodyInk = NSColor(calibratedRed: 0.23, green: 0.28, blue: 0.36, alpha: 1)

background.setFill()
canvas.fill()

header.setFill()
NSRect(x: 0, y: 310, width: size.width, height: 130).fill()
blue.withAlphaComponent(0.85).setFill()
NSRect(x: 0, y: 310, width: 4, height: 130).fill()

drawText(
    "BUSYCAT",
    at: NSPoint(x: 48, y: 365),
    font: .systemFont(ofSize: 30, weight: .bold),
    color: .white,
    tracking: 1.8
)
drawText(
    "CPU + GPU, one busy cat",
    at: NSPoint(x: 49, y: 334),
    font: .systemFont(ofSize: 15, weight: .medium),
    color: NSColor.white.withAlphaComponent(0.64)
)

let graph = NSBezierPath()
graph.move(to: NSPoint(x: 450, y: 347))
graph.curve(
    to: NSPoint(x: 492, y: 353),
    controlPoint1: NSPoint(x: 464, y: 347),
    controlPoint2: NSPoint(x: 477, y: 339)
)
graph.curve(
    to: NSPoint(x: 536, y: 369),
    controlPoint1: NSPoint(x: 509, y: 368),
    controlPoint2: NSPoint(x: 519, y: 370)
)
graph.curve(
    to: NSPoint(x: 612, y: 349),
    controlPoint1: NSPoint(x: 558, y: 366),
    controlPoint2: NSPoint(x: 582, y: 345)
)
blue.withAlphaComponent(0.78).setStroke()
graph.lineWidth = 3
graph.lineCapStyle = .round
graph.stroke()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 282, y: 205))
arrow.line(to: NSPoint(x: 378, y: 205))
blue.withAlphaComponent(0.90).setStroke()
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 363, y: 220))
arrowHead.line(to: NSPoint(x: 379, y: 205))
arrowHead.line(to: NSPoint(x: 363, y: 190))
blue.withAlphaComponent(0.90).setStroke()
arrowHead.lineWidth = 4
arrowHead.lineCapStyle = .round
arrowHead.lineJoinStyle = .round
arrowHead.stroke()

drawText(
    "DRAG TO INSTALL",
    at: NSPoint(x: 267, y: 135),
    font: .systemFont(ofSize: 11, weight: .semibold),
    color: bodyInk.withAlphaComponent(0.58),
    tracking: 1.5
)

drawText(
    "macOS 13+  |  Apple Silicon",
    at: NSPoint(x: 48, y: 50),
    font: .systemFont(ofSize: 12, weight: .medium),
    color: bodyInk.withAlphaComponent(0.58)
)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Could not render DMG background\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
