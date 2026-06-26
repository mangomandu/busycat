/*
 AppDelegate.swift — full BusyCat on the light CALayer renderer.

 Rendering: cat in a CALayer; the runner timer swaps spriteLayer.contents (no
 button.image → no macOS 26 menu-bar background recomposite → ~0.3% CPU).

 Colour: CALayer contents can't auto-invert like a template image, and no
 light/dark API reliably reports a *dark menu bar under Light Mode* (dark
 wallpaper). So we tint manually and expose a "고양이 색" override
 (자동/흰색/검정): 자동 follows the system Dark/Light mode, and the manual
 choices are a bulletproof escape when 자동 guesses wrong.

 Speed follows RunCat's curve at half the frame rate; CPU% uses the same model.
 Heavy metrics (disk/net/battery) are sampled only while the menu is open.
*/

import Cocoa
import QuartzCore
import ServiceManagement

enum SpeedDriver: String, CaseIterable {
    case busiest, cpu, gpu, memory
    var label: String {
        switch self {
        case .busiest: return "가장 바쁜 쪽"
        case .cpu: return "CPU 사용률"
        case .gpu: return "GPU 부하"
        case .memory: return "메모리 사용률"
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

enum MeterColor: String, CaseIterable {
    case graphite, accent, blue, green, orange, purple
    var label: String {
        switch self {
        case .graphite: return "흑연"
        case .accent: return "시스템 강조색"
        case .blue: return "파랑"
        case .green: return "초록"
        case .orange: return "주황"
        case .purple: return "보라"
        }
    }
    var color: NSColor {
        switch self {
        case .graphite:
            return .systemGray
        case .accent: return .controlAccentColor
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .purple: return .systemPurple
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
    private var lastTintKey = ""

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
    private var meterColor: MeterColor {
        get { MeterColor(rawValue: defaults.string(forKey: "meterColor") ?? "") ?? .graphite }
        set { defaults.set(newValue.rawValue, forKey: "meterColor") }
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
    private var thermalCatTint: Bool {
        get { defaults.bool(forKey: "thermalCatTint") }
        set { defaults.set(newValue, forKey: "thermalCatTint") }
    }

    private let statsView = StatsView()
    private var cpuHistory: [Double] = []
    private var driverItems: [NSMenuItem] = []
    private var catColorItems: [NSMenuItem] = []
    private var meterColorItems: [NSMenuItem] = []
    private var showTextItem: NSMenuItem!
    private var invertItem: NSMenuItem!
    private var flipItem: NSMenuItem!
    private var thermalCatItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var speedStatusItem: NSMenuItem!
    private var thermalParentItem: NSMenuItem!
    private let thermalMenu = NSMenu()
    private var thermalMenuSignature = ""
    private var availableUpdate: String?
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
        _ = sampler.sampleLight()
        startAnimation(interval: currentInterval)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.2
        // .common so it keeps firing while the menu is open (event-tracking mode),
        // otherwise the panel only refreshes on close/reopen.
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
        tick()
        maybeAutoCheckUpdate()
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
        // Sprite frames must switch immediately. Prevent Core Animation from
        // creating an implicit contents animation for every timer tick.
        spriteLayer.actions = ["contents": NSNull()]
        textLayer.contentsScale = scale
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.alignmentMode = .left
        textLayer.isHidden = true
        container.layer?.addSublayer(textLayer)
        container.layer?.addSublayer(spriteLayer)
    }

    private func baseCatColor() -> NSColor {
        switch catColor {
        case .white: return .white
        case .black: return .black
        case .auto:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
        }
    }

    private func catTintColor() -> NSColor {
        if thermalCatTint,
           ProcessInfo.processInfo.thermalState != .nominal {
            return NSColor(calibratedRed: 0.93, green: 0.48, blue: 0.42, alpha: 1)
        }
        return baseCatColor()
    }

    private func catTintKey() -> String {
        if thermalCatTint,
           ProcessInfo.processInfo.thermalState != .nominal {
            return "thermal-coral"
        }
        switch catColor {
        case .white: return "white"
        case .black: return "black"
        case .auto:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "auto-white" : "auto-black"
        }
    }

    private func rebuildArtwork() {
        lastTintKey = catTintKey()
        let color = catTintColor()
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

        speedStatusItem = NSMenuItem(title: speedStatusTitle(for: latest), action: nil, keyEquivalent: "")
        menu.addItem(speedStatusItem)

        thermalParentItem = NSMenuItem(title: "온도 상세", action: nil, keyEquivalent: "")
        thermalParentItem.submenu = thermalMenu
        menu.addItem(thermalParentItem)
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

        let meterParent = NSMenuItem(title: "그래프/바 색", action: nil, keyEquivalent: "")
        let meterMenu = NSMenu()
        for c in MeterColor.allCases {
            let it = NSMenuItem(title: c.label, action: #selector(selectMeterColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.rawValue
            it.state = (c == meterColor) ? .on : .off
            meterMenu.addItem(it)
            meterColorItems.append(it)
        }
        meterParent.submenu = meterMenu
        menu.addItem(meterParent)

        showTextItem = toggle("메뉴바에 % 표시", #selector(toggleShowText), showText)
        invertItem = toggle("속도 반전 (바쁘면 느리게)", #selector(toggleInvert), invert)
        flipItem = toggle("좌우 반전", #selector(toggleFlip), flip)
        thermalCatItem = toggle("열 압박 시 고양이 코랄색", #selector(toggleThermalCatTint), thermalCatTint)
        loginItem = toggle("로그인 시 자동 실행", #selector(toggleLogin), isLoginEnabled())
        for it in [showTextItem!, invertItem!, flipItem!, thermalCatItem!, loginItem!] { menu.addItem(it) }

        menu.addItem(.separator())
        let activity = NSMenuItem(title: "활성 상태 보기 열기",
                                  action: #selector(openActivityMonitor), keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)
        updateItem = NSMenuItem(title: "업데이트 확인",
                                action: #selector(updateItemClicked), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
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
            latest.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        }
        cpuHistory.append(latest.cpu)
        if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        if menuOpen {
            statsView.update(latest, history: cpuHistory, meterColor: meterColor.color)
            updateSpeedStatusItem()
            updateThermalMenu(latest)
        }
        if catTintKey() != lastTintKey { rebuildArtwork() }
        if showText { layout() }

        guard !asleep else { return }
        var usage = driver.value(latest)
        if invert { usage = 100 - usage }
        let target = SpeedCurve.interval(forUsage: usage)
        // Relative threshold: only rebuild the timer when the rate changes
        // meaningfully (>10%), so tiny EMA jitter doesn't recreate it every tick.
        // A 49.5↔50 fps difference is invisible; the churn isn't free.
        if abs(target - currentInterval) > currentInterval * 0.1 {
            currentInterval = target
            startAnimation(interval: target)
        }
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

    private func speedLabel(for m: Metrics) -> String {
        switch driver {
        case .busiest:
            return m.gpu > m.cpu ? "가장 바쁜 쪽 (GPU 부하)" : "가장 바쁜 쪽 (CPU 사용률)"
        case .cpu, .gpu, .memory:
            return driver.label
        }
    }

    private func speedStatusTitle(for m: Metrics) -> String {
        "현재 기준 · \(speedLabel(for: m))"
    }

    private func updateSpeedStatusItem() {
        speedStatusItem?.title = speedStatusTitle(for: latest)
    }

    private func updateThermalMenu(_ m: Metrics) {
        let signature = thermalMenuSignature(for: m)
        guard signature != thermalMenuSignature else { return }
        thermalMenuSignature = signature

        thermalMenu.removeAllItems()
        addThermalInfo("최고 센서", temp(m.thermalTemp))
        addThermalInfo("열 압박", thermalState(m.thermalState))
        if let cpu = m.thermalCPUTemp { addThermalInfo("CPU 클러스터", temp(cpu)) }
        if let battery = m.batTemp { addThermalInfo("배터리", temp(battery)) }
        if let limit = m.cpuSpeedLimit { addThermalInfo("CPU 속도 제한", "\(limit)%") }
        if let limit = m.cpuSchedulerLimit { addThermalInfo("스케줄러 제한", "\(limit)%") }
        if let cpus = m.cpuAvailableCPUs { addThermalInfo("사용 가능 CPU", "\(cpus)") }
        addThermalInfo("읽은 온도 채널", "\(m.thermalSensorCount)개")

        thermalMenu.addItem(.separator())
        let header = NSMenuItem(title: "가장 높은 센서", action: nil, keyEquivalent: "")
        header.isEnabled = false
        thermalMenu.addItem(header)

        if m.thermalTopSensors.isEmpty {
            let empty = NSMenuItem(title: "읽힌 온도 센서 없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            thermalMenu.addItem(empty)
        } else {
            for sensor in m.thermalTopSensors {
                let item = NSMenuItem(
                    title: "\(sensor.name) · \(sensor.source): \(temp(sensor.value))",
                    action: nil,
                    keyEquivalent: "")
                item.toolTip = "Apple이 공개 문서로 고정 의미를 보장하지 않는 모델별 센서 이름일 수 있습니다."
                thermalMenu.addItem(item)
            }
        }
    }

    private func thermalMenuSignature(for m: Metrics) -> String {
        var parts: [String] = []
        parts.append(temp(m.thermalTemp))
        parts.append(String(m.thermalState))
        parts.append(temp(m.thermalCPUTemp))
        parts.append(temp(m.batTemp))
        parts.append(m.cpuSpeedLimit.map(String.init) ?? "")
        parts.append(m.cpuSchedulerLimit.map(String.init) ?? "")
        parts.append(m.cpuAvailableCPUs.map(String.init) ?? "")
        parts.append(String(m.thermalSensorCount))
        parts += m.thermalTopSensors.map { "\($0.name):\($0.source):\(String(format: "%.1f", $0.value))" }
        return parts.joined(separator: "|")
    }

    private func addThermalInfo(_ label: String, _ value: String) {
        let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
        thermalMenu.addItem(item)
    }

    private func temp(_ value: Double?) -> String {
        value.map { String(format: "%.1f°C", $0) } ?? "—"
    }

    private func thermalState(_ raw: Int) -> String {
        switch ProcessInfo.ThermalState(rawValue: raw) {
        case .nominal: return "정상"
        case .fair: return "약간 높음"
        case .serious: return "높음"
        case .critical: return "위험"
        default: return "—"
        }
    }

    // MARK: Actions

    @objc private func selectDriver(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let d = SpeedDriver(rawValue: raw)
        else { return }
        driver = d
        for it in driverItems { it.state = (it === sender) ? .on : .off }
        updateSpeedStatusItem()
        tick()
    }

    @objc private func selectCatColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = CatColor(rawValue: raw)
        else { return }
        catColor = c
        for it in catColorItems { it.state = (it === sender) ? .on : .off }
        rebuildArtwork()
    }

    @objc private func selectMeterColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = MeterColor(rawValue: raw)
        else { return }
        meterColor = c
        for it in meterColorItems { it.state = (it === sender) ? .on : .off }
        if menuOpen {
            statsView.update(latest, history: cpuHistory, meterColor: c.color)
        }
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

    @objc private func toggleThermalCatTint() {
        thermalCatTint.toggle()
        thermalCatItem.state = thermalCatTint ? .on : .off
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

    // MARK: Update check

    /// Click the update menu item: open the download page if an update is known,
    /// otherwise run a manual check and report the result.
    @objc private func updateItemClicked() {
        if availableUpdate != nil {
            NSWorkspace.shared.open(Updater.releasesPage)
            return
        }
        updateItem.title = "업데이트 확인 중…"
        updateItem.action = nil
        Updater.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .updateAvailable(let v):
                self.setUpdateAvailable(v)
                NSWorkspace.shared.open(Updater.releasesPage)
            case .upToDate:
                self.updateItem.title = "업데이트 확인"
                self.updateItem.action = #selector(self.updateItemClicked)
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "최신 버전입니다"
                a.informativeText = "현재 v\(Updater.currentVersion)이 최신입니다."
                a.runModal()
            case .failed:
                self.updateItem.title = "업데이트 확인"
                self.updateItem.action = #selector(self.updateItemClicked)
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "업데이트를 확인할 수 없습니다"
                a.informativeText = "네트워크 연결을 확인한 뒤 다시 시도해 주세요."
                a.runModal()
            }
        }
    }

    private func setUpdateAvailable(_ v: String) {
        availableUpdate = v
        updateItem.title = "🆕 새 버전 v\(v) 받기"
        updateItem.action = #selector(updateItemClicked)
        updateItem.target = self
    }

    /// Quiet background check, at most once per day.
    private func maybeAutoCheckUpdate() {
        let key = "lastUpdateCheck"
        let now = Date().timeIntervalSince1970
        guard now - defaults.double(forKey: key) > 24 * 3600 else { return }
        Updater.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .updateAvailable(let v):
                self.defaults.set(now, forKey: key)
                self.setUpdateAvailable(v)
            case .upToDate:
                self.defaults.set(now, forKey: key)
            case .failed:
                break // retry on the next launch instead of suppressing for 24h
            }
        }
    }

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
        _ = sampler.sampleLight()
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
