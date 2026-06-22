import AppKit

/// Debug-only: renders every cat frame to a PNG (black cat composited on white)
/// so the artwork can be inspected outside the menu bar.
enum FrameDumper {
    static func dump(to dir: String, height: CGFloat) {
        let frames = CatFrames.load(height: height)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        for (i, frame) in frames.enumerated() {
            let size = frame.size
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * 2),
                pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            rep.size = size

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            frame.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()

            if let data = rep.representation(using: .png, properties: [:]) {
                let path = (dir as NSString).appendingPathComponent(String(format: "frame_%02d.png", i))
                try? data.write(to: URL(fileURLWithPath: path))
                FileHandle.standardOutput.write(Data((path + "\n").utf8))
            }
        }
    }
}
