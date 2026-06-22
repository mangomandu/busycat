/*
 AppDelegate.swift — light-render improvement over the vanilla RunCat clone.

 Same RunCat logic (CPU-driven, `0.2 / clamp(usage/5, 1...20)` speed, 5 s CPU
 sampling), but the cat is drawn into a CALayer and animated by swapping
 `layer.contents` from a timer — NOT by setting `button.image`.

 Why: on macOS 26, setting `button.image` each frame makes the status item
 redraw through NSStatusBarButtonCell → drawBackgroundInRect:, recompositing the
 translucent menu-bar background every frame (~5% CPU here for identical code,
 vs ~0.8% for the App Store RunCat). Updating a sublayer's contents skips the
 cell/background redraw entirely, so it's cheap — and because we step frames
 manually on a timer (no CAKeyframeAnimation clock to re-time), it never stutters.
 Rendering being cheap means we can drop the fps cap and match RunCat's 5→100 fps.

 Manual tinting is required because CALayer contents don't auto-invert like a
 template image; we re-tint on dark/light changes.
*/

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let barHeight: CGFloat = 18
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private lazy var statusItem: NSStatusItem = {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }()
    private let menu = NSMenu()
    private let container = NSView()
    private let spriteLayer = CALayer()
    private let textLayer = CATextLayer()
    private var tintedFrames: [CGImage] = []
    private var tintIsLight = true

    private var index = 0
    private var interval: Double = 1.0
    private let cpu = CPU()
    private var usage: CPUInfo = CPU.default
    private var cpuTimer: Timer?
    private var runnerTimer: Timer?
    private var isShowUsage = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupSprite()
        setupMenu()
        rebuildArtwork()
        layout()
        startRunning()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRunning()
    }

    // MARK: Sprite (cat drawn in a sublayer, not button.image)

    private func setupSprite() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = ""
        button.wantsLayer = true
        let thickness = NSStatusBar.system.thickness
        container.frame = NSRect(x: 0, y: 0, width: thickness, height: thickness)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        button.addSubview(container)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.contentsScale = scale
        textLayer.contentsScale = scale
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.alignmentMode = .left
        textLayer.isHidden = true
        container.layer?.addSublayer(textLayer)
        container.layer?.addSublayer(spriteLayer)
    }

    private func rebuildArtwork() {
        tintIsLight = isLightMenuBar()
        let color: NSColor = tintIsLight ? .black : .white
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        tintedFrames = CatFrames.load(height: barHeight).compactMap { tinted($0, color: color, scale: scale) }
        textLayer.foregroundColor = color.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if index >= tintedFrames.count { index = 0 }
        spriteLayer.contents = tintedFrames.first
        CATransaction.commit()
    }

    private func tinted(_ image: NSImage, color: NSColor, scale: CGFloat) -> CGImage? {
        let w = Int((image.size.width * scale).rounded())
        let h = Int((image.size.height * scale).rounded())
        guard w > 0, h > 0,
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private func isLightMenuBar() -> Bool {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
    }

    private func layout() {
        let thickness = NSStatusBar.system.thickness
        let catW = (barHeight * 56 / 36).rounded()
        let catY = ((thickness - barHeight) / 2).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var x: CGFloat = 0
        if isShowUsage {
            let s = usage.description
            let tw = (s as NSString).size(withAttributes: [.font: font]).width.rounded() + 4
            let lh = (font.ascender - font.descender).rounded()
            textLayer.isHidden = false
            textLayer.string = s
            textLayer.frame = CGRect(x: 0, y: ((thickness - lh) / 2).rounded(), width: tw, height: lh)
            x = tw
        } else {
            textLayer.isHidden = true
        }
        spriteLayer.frame = CGRect(x: x, y: catY, width: catW, height: barHeight)
        statusItem.length = x + catW
        CATransaction.commit()
    }

    // MARK: Menu

    private func setupMenu() {
        menu.addItem(withTitle: "Show CPU Usage", action: #selector(toggleShowUsage(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "About", action: #selector(openAbout(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(terminateApp(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func toggleShowUsage(_ sender: NSMenuItem) {
        isShowUsage = (sender.state == .off)
        sender.state = isShowUsage ? .on : .off
        layout()
    }

    @objc func openAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc func terminateApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: Run loop (RunCat timing; only the frame swap differs)

    private func startRunning() {
        cpuTimer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in self?.updateUsage() }
        RunLoop.main.add(cpuTimer!, forMode: .common)
        cpuTimer?.fire()
    }

    private func stopRunning() {
        runnerTimer?.invalidate()
        cpuTimer?.invalidate()
    }

    private func updateUsage() {
        usage = cpu.currentUsage()
        if isLightMenuBar() != tintIsLight { rebuildArtwork() }
        interval = 0.2 / max(1.0, min(20.0, usage.value / 5.0))
        if isShowUsage { layout() }
        runnerTimer?.invalidate()
        runnerTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.next() }
        RunLoop.main.add(runnerTimer!, forMode: .common)
    }

    private func next() {
        guard !tintedFrames.isEmpty else { return }
        index = (index + 1) % tintedFrames.count
        // The cheap part: swap one layer's contents — no cell/background redraw.
        spriteLayer.contents = tintedFrames[index]
    }
}
