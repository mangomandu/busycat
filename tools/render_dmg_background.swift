import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? ".build/dmg/background.png"
let size = NSSize(width: 520, height: 740)
let image = NSImage(size: size)

image.lockFocus()

NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()

let panelRect = NSRect(x: 104, y: 120, width: 312, height: 202)
let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 8, yRadius: 8)
NSColor(calibratedRed: 0.88, green: 0.92, blue: 1.0, alpha: 0.88).setFill()
panelPath.fill()

let guidePath = NSBezierPath()
guidePath.move(to: NSPoint(x: 236, y: 496))
guidePath.line(to: NSPoint(x: 284, y: 496))
guidePath.line(to: NSPoint(x: 284, y: 428))
guidePath.line(to: NSPoint(x: 324, y: 428))
guidePath.line(to: NSPoint(x: 260, y: 353))
guidePath.line(to: NSPoint(x: 196, y: 428))
guidePath.line(to: NSPoint(x: 236, y: 428))
guidePath.close()
NSColor(calibratedRed: 0.72, green: 0.80, blue: 1.0, alpha: 0.30).setFill()
guidePath.fill()

let arrowPath = NSBezierPath()
arrowPath.move(to: NSPoint(x: 247, y: 478))
arrowPath.line(to: NSPoint(x: 273, y: 478))
arrowPath.line(to: NSPoint(x: 273, y: 423))
arrowPath.line(to: NSPoint(x: 300, y: 423))
arrowPath.line(to: NSPoint(x: 260, y: 370))
arrowPath.line(to: NSPoint(x: 220, y: 423))
arrowPath.line(to: NSPoint(x: 247, y: 423))
arrowPath.close()
NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.86).setFill()
arrowPath.fill()

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
