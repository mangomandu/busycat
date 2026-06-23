/*
 AppDelegate.swift — full BusyCat on the light CALayer renderer.

 Rendering: cat in a CALayer; the runner timer swaps spriteLayer.contents (no
 button.image → no macOS 26 menu-bar background recomposite → ~0.3% CPU).

 Colour: CALayer contents can't auto-invert like a template image, and no
 light/dark API reliably reports a *dark menu bar under Light Mode* (dark
 wallpaper). So we tint manually and expose a "고양이 색" override
 (자동/흰색/검정): 자동 follows the system Dark/Light mode, and the manual
 choices are a bulletproof escape when 자동 guesses wrong.

 Speed = RunCat's exact curve; CPU% matches RunCat's formula (UsageReader).
 Heavy metrics (disk/net/battery) are sampled only while the menu is open.
*/

import Cocoa
import QuartzCore
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

enum CatColor: String, CaseIterable {
    case auto, white, black
    var label: String {
        switch self {
        case .auto: return "자동 (시스템 모드)"
        case .white: return "흰색"
        case .black: return "검정"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let barHeight: CGFloat = 18
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private lazy var statusItem: NSStatusItem = {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }()
    private let container = NSView()
    private let spriteLayer = CALayer()
    private let textLayer = CATextLayer()
    private var tintedFrames: [CGImage] = []
    private var lastTintWhite = false

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
    private var catColor: CatColor {
        get { CatColor(rawValue: defaults.string(forKey: "catColor") ?? "") ?? .white }
        set { defaults.set(newValue.rawValue, forKey: "catColor") }
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

    private let statsView = StatsView()
    private var cpuHistory: [Double] = []
    private var driverItems: [NSMenuItem] = []
    private var catColorItems: [NSMenuItem] = []
    private var showTextItem: NSMenuItem!
    private var invertItem: NSMenuItem!
    private var flipItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another copy is already running, quit immediately so
        // we never end up with a row of cats.
        let me = NSRunningApplication.current
        let dupes = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.dlfnek.busycat")
            .filter { $0.processIdentifier != me.processIdentifier }
        if !dupes.isEmpty { NSApp.terminate(nil); return }

        setupSprite()
        buildMenu()
        registerSleepWake()
        rebuildArtwork()
        layout()
        _ = sampler.sampleAll()
        startAnimation(interval: currentInterval)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.2
        // .common so it keeps firing while the menu is open (event-tracking mode),
        // otherwise the panel only refreshes on close/reopen.
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runnerTimer?.invalidate()
        sampleTimer?.invalidate()
    }

    // MARK: Sprite

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

    private func wantWhite() -> Bool {
        switch catColor {
        case .white: return true
        case .black: return false
        case .auto:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    private func rebuildArtwork() {
        lastTintWhite = wantWhite()
        let color: NSColor = lastTintWhite ? .white : .black
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        tintedFrames = CatFrames.load(height: barHeight, flipped: flip)
            .compactMap { tinted($0, color: color, scale: scale) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.foregroundColor = color.cgColor
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
        let statsItem = NSMenuItem()
        statsItem.view = statsView
        menu.addItem(statsItem)
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

        let colorParent = NSMenuItem(title: "고양이 색", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for c in CatColor.allCases {
            let it = NSMenuItem(title: c.label, action: #selector(selectCatColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.rawValue
            it.state = (c == catColor) ? .on : .off
            colorMenu.addItem(it)
            catColorItems.append(it)
        }
        colorParent.submenu = colorMenu
        menu.addItem(colorParent)

        showTextItem = toggle("메뉴바에 % 표시", #selector(toggleShowText), showText)
        invertItem = toggle("속도 반전 (바쁘면 느리게)", #selector(toggleInvert), invert)
        flipItem = toggle("좌우 반전", #selector(toggleFlip), flip)
        loginItem = toggle("로그인 시 자동 실행", #selector(toggleLogin), isLoginEnabled())
        for it in [showTextItem!, invertItem!, flipItem!, loginItem!] { menu.addItem(it) }

        menu.addItem(.separator())
        let activity = NSMenuItem(title: "활성 상태 보기 열기",
                                  action: #selector(openActivityMonitor), keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)
        let quit = NSMenuItem(title: "바쁘냥 종료", action: #selector(quit), keyEquivalent: "q")
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
            latest = sampler.sampleAll()   // full detail while the panel is visible
        } else {
            let light = sampler.sampleLight()
            latest.cpu = light.cpu
            latest.gpu = light.gpu
            latest.memory = light.memory
        }
        cpuHistory.append(latest.cpu)
        if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        if menuOpen { statsView.update(latest, history: cpuHistory) }
        if catColor == .auto, wantWhite() != lastTintWhite { rebuildArtwork() }
        if showText { layout() }

        guard !asleep else { return }
        var usage = driver.value(latest)
        if invert { usage = 100 - usage }
        let target = interval(forUsage: usage)
        // Relative threshold: only rebuild the timer when the rate changes
        // meaningfully (>10%), so tiny EMA jitter doesn't recreate it every tick.
        // A 49.5↔50 fps difference is invisible; the churn isn't free.
        if abs(target - currentInterval) > currentInterval * 0.1 {
            currentInterval = target
            startAnimation(interval: target)
        }
    }

    /// Frame interval from load. Half of RunCat's rate (0.4 vs 0.2 base) for a
    /// calmer cat: ~2.5 fps idle … ~50 fps at full load.
    private func interval(forUsage usage: Double) -> TimeInterval {
        return 0.4 / max(1.0, min(20.0, usage / 5.0))
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
        spriteLayer.contents = tintedFrames[index]
    }

    // MARK: Actions

    @objc private func selectDriver(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let d = SpeedDriver(rawValue: raw)
        else { return }
        driver = d
        for it in driverItems { it.state = (it === sender) ? .on : .off }
        tick()
    }

    @objc private func selectCatColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = CatColor(rawValue: raw)
        else { return }
        catColor = c
        for it in catColorItems { it.state = (it === sender) ? .on : .off }
        rebuildArtwork()
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

    @objc private func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
            } catch { NSLog("BusyCat login item error: \(error)") }
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
