import AppKit
import ServiceManagement

/// Which metric drives the cat's running speed.
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

/// Rendering uses RunCat's proven method: a timer swaps the status item's template
/// image frame by frame ("flip-book"). AppKit handles tinting, click-highlight and
/// layout for free, and — crucially — there is no self-running animation clock to
/// re-sync when the speed changes, so it never stutters. (Core Animation is cheaper
/// but its self-playing clock must be re-timed on every speed change, and since the
/// driving metric fluctuates each second that re-timing hitches — the "뛰다말다".)
/// The only addition over RunCat is `maxFPS`, capping top speed to bound CPU.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let barHeight: CGFloat = 18
    private let maxFPS: Double = 25
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private var statusItem: NSStatusItem!
    private var frames: [NSImage] = []
    private var index = 0

    private var animationTimer: Timer?
    private var sampleTimer: Timer?
    private var currentInterval: TimeInterval = 0.2
    private var asleep = false

    private let sampler = SystemSampler()
    private var latest = Metrics()
    private var menuOpen = false

    // Persisted settings
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

    // Menu items kept around for live updates
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        reloadFrames()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageTrailing  // % text (if any) left of cat
        statusItem.button?.image = frames.first
        statusItem.button?.font = font
        buildMenu()
        registerSleepWake()

        _ = sampler.sampleAll()  // prime tick/byte counters
        startAnimation(interval: currentInterval)
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        sampleTimer?.tolerance = 0.2
        tick()
    }

    // MARK: Frames (RunCat-style flip-book)

    private func reloadFrames() {
        frames = CatFrames.load(height: barHeight, flipped: flip)
        index = 0
        statusItem?.button?.image = frames.first
    }

    private func startAnimation(interval: TimeInterval) {
        animationTimer?.invalidate()
        guard !frames.isEmpty else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)  // keep running while menu is open
        animationTimer = timer
    }

    private func advanceFrame() {
        guard !frames.isEmpty else { return }
        index = (index + 1) % frames.count
        statusItem.button?.image = frames[index]
    }

    /// RunCat's mapping: `0.2 / clamp(usage/5, 1...20)` → 0.2s (5 fps) at idle,
    /// faster as load rises. `max(1, …)` floors it, so no idle threshold is needed.
    /// Clamped to `maxFPS` so the monitor's own CPU stays bounded under full load.
    private func interval(forUsage usage: Double) -> TimeInterval {
        let speed = max(1.0, min(20.0, usage / 5.0))
        return max(1.0 / maxFPS, 0.2 / speed)
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
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

    // MARK: Sampling

    private func tick() {
        if menuOpen {
            latest = sampler.sampleAll()        // full detail only while visible
            refreshMenuTitles()                 // rows aren't visible when closed
        } else {
            let light = sampler.sampleLight()   // cheap: just what drives the cat
            latest.cpu = light.cpu
            latest.gpu = light.gpu
            latest.memory = light.memory
            // disk/net/battery keep their last values until the menu reopens
        }
        if showText { updateStatusText() }      // menu-bar % only if enabled
        guard !asleep else { return }

        var usage = driver.value(latest)
        if invert { usage = 100 - usage }
        let target = interval(forUsage: usage)
        if abs(target - currentInterval) > 0.003 {
            currentInterval = target
            startAnimation(interval: target)  // seamless: frame index is preserved
        }
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

    private func updateStatusText() {
        statusItem.button?.title = showText ? String(format: "%.0f%% ", driver.value(latest)) : ""
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
        updateStatusText()
    }

    @objc private func toggleInvert() {
        invert.toggle()
        invertItem.state = invert ? .on : .off
        tick()
    }

    @objc private func toggleFlip() {
        flip.toggle()
        flipItem.state = flip ? .on : .off
        reloadFrames()
    }

    @objc private func toggleLogin() {
        setLogin(!isLoginEnabled())
        loginItem.state = isLoginEnabled() ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Login item

    private func isLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    private func setLogin(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("RuncatGPU login item error: \(error)")
            }
        }
    }

    // MARK: Sleep / wake (pause animation while asleep, like RunCat)

    private func registerSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(onSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func onSleep() {
        asleep = true
        animationTimer?.invalidate()
        animationTimer = nil
    }

    @objc private func onWake() {
        asleep = false
        _ = sampler.sampleAll()
        startAnimation(interval: currentInterval)
    }
}

// Update the full metric set only while the menu is on screen.
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        tick()  // fill disk/net/battery before the rows are shown
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }
}
