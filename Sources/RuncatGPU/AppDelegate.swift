/*
 AppDelegate.swift — full RuncatGPU on the light (CALayer) renderer.

 Combines:
   • light-render: cat drawn in a sublayer, animated by swapping layer.contents
     from a timer (no button.image → no menu-bar background recomposite; no
     CAKeyframeAnimation clock → no stutter). ~0.5% CPU on macOS 26.
   • full features: GPU + CPU + memory + disk + network + battery, selectable
     speed driver, show-%/invert/flip/launch-at-login, sleep-wake. The costly
     metrics are sampled only while the menu is open.

 Speed curve is a gentle linear idleFPS→maxFPS (calmer than RunCat's fps==usage%);
 both ends are tunable constants below.
*/

import Cocoa
import ServiceManagement

enum SpeedDriver: String, CaseIterable {
    case busiest, cpu, gpu, memory

    var label: String {
        switch self {
        case .busiest: return "가장 바쁜 쪽 (CPU·GPU)"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "메모리"
        }
    }

    func value(_ m: Metrics) -> Double {
        switch self {
        case .busiest: return max(m.cpu, m.gpu)
        case .cpu: return m.cpu
        case .gpu: return m.gpu
        case .memory: return m.memory
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let barHeight: CGFloat = 18
    private let idleFPS = 5.0    // speed at ~0% load
    private let maxFPS = 22.0    // speed at 100% load (tune to taste)
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private lazy var statusItem: NSStatusItem = {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }()
    private let container = NSView()
    private let spriteLayer = CALayer()
    private let textLayer = CATextLayer()
    private var tintedFrames: [CGImage] = []
    private var tintIsLight = true

    private var index = 0
    private var runnerTimer: Timer?
    private var sampleTimer: Timer?
    private var currentInterval: TimeInterval = 0.2
    private var asleep = false

    private let sampler = SystemSampler()
    private var latest = Metrics()
    private var menuOpen = false

    private let defaults = UserDefaults.standard
    private var driver: SpeedDriver {
        get { SpeedDriver(rawValue: defaults.string(forKey: "driver") ?? "") ?? .busiest }
        set { defaults.set(newValue.rawValue, forKey: "driver") }
    }
    private var showText: Bool {
        get { defaults.bool(forKey: "showText") }
        set { defaults.set(newValue, forKey: "showText") }
    }
    private var invert: Bool {
        get { defaults.bool(forKey: "invert") }
        set { defaults.set(newValue, forKey: "invert") }
    }
    private var flip: Bool {
        get { defaults.bool(forKey: "flip") }
        set { defaults.set(newValue, forKey: "flip") }
    }

    private let cpuItem = NSMenuItem(title: "CPU", action: nil, keyEquivalent: "")
    private let gpuItem = NSMenuItem(title: "GPU", action: nil, keyEquivalent: "")
    private let memItem = NSMenuItem(title: "메모리", action: nil, keyEquivalent: "")
    private let diskItem = NSMenuItem(title: "디스크", action: nil, keyEquivalent: "")
    private let netItem = NSMenuItem(title: "네트워크", action: nil, keyEquivalent: "")
    private let batItem = NSMenuItem(title: "배터리", action: nil, keyEquivalent: "")
    private var driverItems: [NSMenuItem] = []
    private var showTextItem: NSMenuItem!
    private var invertItem: NSMenuItem!
    private var flipItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupSprite()
        buildMenu()
        registerSleepWake()
        rebuildArtwork()
        layout()
        _ = sampler.sampleAll()  // prime counters
        startAnimation(interval: currentInterval)
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        sampleTimer?.tolerance = 0.2
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runnerTimer?.invalidate()
        sampleTimer?.invalidate()
    }

    // MARK: Sprite (cat in a sublayer; contents swapped by the timer)

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
        tintedFrames = CatFrames.load(height: barHeight, flipped: flip)
            .compactMap { tinted($0, color: color, scale: scale) }
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
        if showText {
            let s = String(format: "%.0f%%", driver.value(latest))
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

    private func buildMenu() {
        for item in [cpuItem, gpuItem, memItem, diskItem, netItem, batItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let driverParent = NSMenuItem(title: "속도 기준", action: nil, keyEquivalent: "")
        let driverMenu = NSMenu()
        for d in SpeedDriver.allCases {
            let it = NSMenuItem(title: d.label, action: #selector(selectDriver(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = d.rawValue
            it.state = (d == driver) ? .on : .off
            driverMenu.addItem(it)
            driverItems.append(it)
        }
        driverParent.submenu = driverMenu
        menu.addItem(driverParent)

        showTextItem = toggle("메뉴바에 % 표시", #selector(toggleShowText), showText)
        invertItem = toggle("속도 반전 (바쁘면 느리게)", #selector(toggleInvert), invert)
        flipItem = toggle("좌우 반전", #selector(toggleFlip), flip)
        loginItem = toggle("로그인 시 자동 실행", #selector(toggleLogin), isLoginEnabled())
        for it in [showTextItem!, invertItem!, flipItem!, loginItem!] { menu.addItem(it) }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "RuncatGPU 종료", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        statusItem.menu = menu
    }

    private func toggle(_ title: String, _ action: Selector, _ on: Bool) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.state = on ? .on : .off
        return it
    }

    // MARK: Sampling + animation

    private func tick() {
        if menuOpen {
            latest = sampler.sampleAll()
            refreshMenuTitles()
        } else {
            let light = sampler.sampleLight()
            latest.cpu = light.cpu
            latest.gpu = light.gpu
            latest.memory = light.memory
        }
        if showText { layout() }

        guard !asleep else { return }
        var usage = driver.value(latest)
        if invert { usage = 100 - usage }
        let target = interval(forUsage: usage)
        if abs(target - currentInterval) > 0.003 {
            currentInterval = target
            startAnimation(interval: target)  // index preserved → seamless
        }
    }

    /// Gentle linear map: idle→idleFPS, full load→maxFPS.
    private func interval(forUsage usage: Double) -> TimeInterval {
        let u = max(0, min(100, usage)) / 100
        return 1.0 / (idleFPS + u * (maxFPS - idleFPS))
    }

    private func startAnimation(interval: TimeInterval) {
        runnerTimer?.invalidate()
        guard !tintedFrames.isEmpty else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.next() }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        runnerTimer = timer
    }

    private func next() {
        guard !tintedFrames.isEmpty else { return }
        index = (index + 1) % tintedFrames.count
        spriteLayer.contents = tintedFrames[index]  // cheap: no cell/background redraw
    }

    private func refreshMenuTitles() {
        cpuItem.title = String(format: "CPU         %5.1f%%", latest.cpu)
        gpuItem.title = String(format: "GPU         %5.1f%%", latest.gpu)
        memItem.title = String(format: "메모리      %5.1f%%", latest.memory)
        diskItem.title = String(format: "디스크      %5.1f%%", latest.disk)
        netItem.title = "네트워크  ↓\(rate(latest.netDown))  ↑\(rate(latest.netUp))"
        if let b = latest.battery {
            batItem.title = "배터리      \(b)%\(latest.charging ? " ⚡" : "")"
        } else {
            batItem.title = "배터리      —"
        }
    }

    private func rate(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1fMB/s", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0fKB/s", bps / 1_000) }
        return String(format: "%.0fB/s", bps)
    }

    // MARK: Actions

    @objc private func selectDriver(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let d = SpeedDriver(rawValue: raw)
        else { return }
        driver = d
        for it in driverItems { it.state = (it === sender) ? .on : .off }
        tick()
    }

    @objc private func toggleShowText() {
        showText.toggle()
        showTextItem.state = showText ? .on : .off
        layout()
    }

    @objc private func toggleInvert() {
        invert.toggle()
        invertItem.state = invert ? .on : .off
        tick()
    }

    @objc private func toggleFlip() {
        flip.toggle()
        flipItem.state = flip ? .on : .off
        rebuildArtwork()
    }

    @objc private func toggleLogin() {
        setLogin(!isLoginEnabled())
        loginItem.state = isLoginEnabled() ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func isLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    private func setLogin(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("RuncatGPU login item error: \(error)") }
        }
    }

    // MARK: Sleep / wake

    private func registerSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(onSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func onSleep() {
        asleep = true
        runnerTimer?.invalidate()
        runnerTimer = nil
    }

    @objc private func onWake() {
        asleep = false
        _ = sampler.sampleAll()
        startAnimation(interval: currentInterval)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        tick()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }
}
