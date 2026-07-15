/*
 AppDelegate.swift — full BusyCat on the light CALayer renderer.

 Rendering: cat in a CALayer; the runner timer swaps spriteLayer.contents (no
 button.image → no macOS 26 menu-bar background recomposite → ~0.3% CPU).

 Colour: CALayer contents can't auto-invert like a template image, so we tint
 manually and expose a "고양이 색" override (자동/흰색/검정). 자동 resolves the
 status-bar button's label color first, then falls back to system appearance.

 Speed follows RunCat's curve at half the frame rate; CPU% uses the same model.
 Detailed metrics are prewarmed once in the background, then refreshed while
 the menu is open.
*/

import Cocoa
import QuartzCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let barHeight: CGFloat = 18
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private lazy var statusItem: NSStatusItem = {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }()
    private let container = StatusContainerView()
    private let spriteLayer = CALayer()
    private let textLayer = CATextLayer()
    private let fishLayer = CALayer()
    private var tintedFrames: [CGImage] = []
    private var lastTintKey = ""
    private var lastFishLevel = -1
    private var cachedAutomaticCatColor = NSColor.white
    private var lastAutomaticColorCheck = Date.distantPast
    private let automaticColorCheckInterval: TimeInterval = 3

    private var index = 0
    private var runnerTimer: Timer?
    private var sampleTimer: Timer?
    private var updateTimer: Timer?
    private var currentInterval: TimeInterval = 0.2
    private var asleep = false

    private let sampling = SamplingCoordinator()
    private var samplingInFlight = false
    private var fullSamplePending = false
    private var latest = Metrics()
    private var menuOpen = false

    private let defaults = UserDefaults.standard
    private var language: AppLanguage {
        get { AppLanguage.current }
        set {
            if newValue == .system {
                defaults.removeObject(forKey: "language")
            } else {
                defaults.set(newValue.rawValue, forKey: "language")
            }
        }
    }
    private var driver: SpeedDriver {
        get { SpeedDriver(rawValue: defaults.string(forKey: "driver") ?? "") ?? .busiest }
        set { defaults.set(newValue.rawValue, forKey: "driver") }
    }
    private var catColor: CatColor {
        get { CatColor(rawValue: defaults.string(forKey: "catColor") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "catColor") }
    }
    private var meterColor: MeterColor {
        get { MeterColor(rawValue: defaults.string(forKey: "meterColor") ?? "") ?? .graphite }
        set { defaults.set(newValue.rawValue, forKey: "meterColor") }
    }
    private var statusTextMode: StatusTextMode {
        get {
            if let raw = defaults.string(forKey: "statusTextMode"),
               let mode = StatusTextMode(rawValue: raw) {
                return mode
            }
            return defaults.bool(forKey: "showText") ? .driver : .off
        }
        set {
            defaults.set(newValue.rawValue, forKey: "statusTextMode")
            defaults.set(newValue != .off, forKey: "showText")
        }
    }
    private var memoryFish: Bool {
        get { defaults.bool(forKey: "memoryFish") }
        set { defaults.set(newValue, forKey: "memoryFish") }
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
    private var updateItem: NSMenuItem!
    private var speedStatusItem: NSMenuItem!
    private var speedStatusView: SpeedStatusRowView?
    private var availableUpdate: String?
    private let menu = NSMenu()
    private var settingsPanel: NSPanel?
    private var thermalPopover: NSPopover?
    private var thermalPopoverDirty = true
    private var firstLaunchPopover: NSPopover?
    private var updateCheckInFlight = false
    private var lastUpdateAttempt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another copy is already running, quit immediately so
        // we never end up with a row of cats.
        let me = NSRunningApplication.current
        let dupes = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.dlfnek.busycat")
            .filter { $0.processIdentifier != me.processIdentifier }
        if !dupes.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = appText("바쁘냥이 이미 실행 중입니다", "BusyCat is already running")
            alert.informativeText = appText(
                "업데이트한 앱을 실행하려면 메뉴바의 기존 바쁘냥을 종료한 뒤 다시 열어 주세요.",
                "To launch an updated copy, quit the existing BusyCat from the menu bar and open it again.")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        setupSprite()
        statsView.onThermalHoverChanged = { [weak self] hovering, rect in
            hovering ? self?.showThermalPopover(relativeTo: rect) : self?.hideThermalPopover()
        }
        buildMenu()
        registerSleepWake()
        rebuildArtwork()
        layout()
        startAnimation(interval: currentInterval)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.requestSample()
        }
        timer.tolerance = 0.2
        // .common so it keeps firing while the menu is open (event-tracking mode),
        // otherwise the panel only refreshes on close/reopen.
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
        // Warm the expensive detail cache in the background. Opening the menu
        // immediately after launch still displays the current cached snapshot.
        requestSample(full: true)
        startUpdateSchedule()
        maybeAutoCheckUpdate()
        showFirstLaunchHintIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runnerTimer?.invalidate()
        sampleTimer?.invalidate()
        updateTimer?.invalidate()
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

        let scale = currentBackingScale()
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.contentsScale = scale
        spriteLayer.magnificationFilter = .linear
        spriteLayer.minificationFilter = .linear
        // Sprite frames must switch immediately. Prevent Core Animation from
        // creating an implicit contents animation for every timer tick.
        spriteLayer.actions = ["contents": NSNull()]
        fishLayer.contentsGravity = .resizeAspect
        fishLayer.contentsScale = scale
        fishLayer.actions = ["contents": NSNull()]
        fishLayer.isHidden = true
        textLayer.contentsScale = scale
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.alignmentMode = .left
        textLayer.isHidden = true
        container.layer?.addSublayer(textLayer)
        container.layer?.addSublayer(spriteLayer)
        container.layer?.addSublayer(fishLayer)
        container.onDisplayPropertiesChanged = { [weak self] in
            self?.statusDisplayPropertiesChanged()
        }
        updateStatusAccessibility()
    }

    private func currentBackingScale() -> CGFloat {
        statusItem.button?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func statusDisplayPropertiesChanged() {
        lastAutomaticColorCheck = .distantPast
        rebuildArtwork()
        layout()
    }

    private func baseCatColor() -> NSColor {
        switch catColor {
        case .white: return .white
        case .black: return .black
        case .auto: return automaticCatColor()
        }
    }

    private func automaticCatColor() -> NSColor {
        let now = Date()
        if now.timeIntervalSince(lastAutomaticColorCheck) < automaticColorCheckInterval {
            return cachedAutomaticCatColor
        }
        lastAutomaticColorCheck = now

        let appearance = statusItem.button?.effectiveAppearance ?? container.effectiveAppearance
        var resolvedLabelColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedLabelColor = NSColor.labelColor.usingColorSpace(.deviceRGB)
        }
        if let resolved = resolvedLabelColor {
            cachedAutomaticCatColor = highContrastCatColor(forLabelColor: resolved)
            return cachedAutomaticCatColor
        }
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        cachedAutomaticCatColor = (match == .darkAqua || match == .vibrantDark) ? .white : .black
        return cachedAutomaticCatColor
    }

    private func highContrastCatColor(forLabelColor color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.deviceRGB) else { return .white }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance >= 0.5 ? .white : .black
    }

    private func thermalOutlineActive() -> Bool {
        thermalCatTint && ProcessInfo.processInfo.thermalState != .nominal
    }

    private func thermalOutlineColor() -> NSColor {
        NSColor(calibratedRed: 1.0, green: 0.12, blue: 0.18, alpha: 1)
    }

    private func catTintKey() -> String {
        let prefix = thermalOutlineActive() ? "thermal-outline-" : ""
        switch catColor {
        case .white: return prefix + "white"
        case .black: return prefix + "black"
        case .auto:
            return prefix + "auto-\(colorKey(automaticCatColor()))"
        }
    }

    private func colorKey(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.deviceRGB) else { return "unknown" }
        return String(format: "%.3f-%.3f-%.3f-%.3f",
                      c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    private func rebuildArtwork() {
        lastTintKey = catTintKey()
        let color = baseCatColor()
        let scale = currentBackingScale()
        spriteLayer.contentsScale = scale
        textLayer.contentsScale = scale
        fishLayer.contentsScale = scale
        let frames = CatFrames.load(height: barHeight, flipped: flip)
        if thermalOutlineActive() {
            tintedFrames = frames.compactMap {
                outlined($0, fill: color, outline: thermalOutlineColor(), scale: scale)
            }
        } else {
            tintedFrames = frames.compactMap { tinted($0, color: color, scale: scale) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.foregroundColor = color.cgColor
        if index >= tintedFrames.count { index = 0 }
        spriteLayer.contents = tintedFrames.first
        CATransaction.commit()
        lastFishLevel = -1
    }

    private func tinted(_ image: NSImage, color: NSColor, scale: CGFloat) -> CGImage? {
        tintedImage(image, color: color, scale: scale)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func tintedImage(_ image: NSImage, color: NSColor, scale: CGFloat) -> NSImage? {
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
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: image.size)
        out.addRepresentation(rep)
        out.isTemplate = false
        return out
    }

    private func outlined(_ image: NSImage, fill: NSColor, outline: NSColor, scale: CGFloat) -> CGImage? {
        guard let outlineImage = tintedImage(image, color: outline, scale: scale),
              let fillImage = tintedImage(image, color: fill, scale: scale)
        else { return nil }
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
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(origin: .zero, size: image.size)
        let outlinePx = 1 / scale
        for offset in [
            NSPoint(x: -outlinePx, y: 0),
            NSPoint(x: outlinePx, y: 0),
            NSPoint(x: 0, y: -outlinePx),
            NSPoint(x: 0, y: outlinePx),
        ] {
            outlineImage.draw(in: rect.offsetBy(dx: offset.x, dy: offset.y))
        }
        fillImage.draw(in: rect)
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
        if let s = statusText(for: latest) {
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
        x += catW
        if memoryFish {
            let fishW: CGFloat = 13
            let gap: CGFloat = 3
            fishLayer.isHidden = false
            fishLayer.frame = CGRect(x: x + gap, y: catY, width: fishW, height: barHeight)
            x += gap + fishW
        } else {
            fishLayer.isHidden = true
        }
        statusItem.length = x
        CATransaction.commit()
    }

    // MARK: RAM fish gauge

    private func updateFishPile() {
        guard memoryFish else { return }
        let level = MetricMath.memoryFishLevel(pressure: latest.memoryPressure)
        guard level != lastFishLevel else { return }
        lastFishLevel = level
        let scale = currentBackingScale()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fishLayer.contents = fishPileImage(level: level, scale: scale)
        CATransaction.commit()
    }

    private func fishPileImage(level: Int, scale: CGFloat) -> CGImage? {
        let wPt: CGFloat = 13
        let w = Int((wPt * scale).rounded())
        let h = Int((barHeight * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let color = baseCatColor().withAlphaComponent(0.72).cgColor
        let fishH: CGFloat = 3
        let gap: CGFloat = 0.4
        if level <= 0 {
            let y = (barHeight - fishH) / 2
            let emptyColor = baseCatColor().withAlphaComponent(0.22).cgColor
            drawFish(ctx, x: 1, y: y, w: wPt - 2, h: fishH, color: emptyColor, flip: true)
            return ctx.makeImage()
        }
        let pileH = CGFloat(level) * fishH + CGFloat(max(0, level - 1)) * gap
        let startY = (barHeight - pileH) / 2
        for i in 0..<level {
            drawFish(ctx, x: 1, y: startY + CGFloat(i) * (fishH + gap),
                     w: wPt - 2, h: fishH, color: color, flip: i % 2 == 0)
        }
        return ctx.makeImage()
    }

    private func drawFish(_ ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                          color: CGColor, flip: Bool) {
        ctx.setFillColor(color)
        let bodyW = w * 0.72
        let tailW = w - bodyW
        let bodyX = flip ? x + (w - bodyW) : x
        ctx.fillEllipse(in: CGRect(x: bodyX, y: y, width: bodyW, height: h))
        let tx = flip ? bodyX : bodyX + bodyW
        let dir: CGFloat = flip ? -1 : 1
        ctx.beginPath()
        ctx.move(to: CGPoint(x: tx, y: y + h / 2))
        ctx.addLine(to: CGPoint(x: tx + dir * tailW, y: y))
        ctx.addLine(to: CGPoint(x: tx + dir * tailW, y: y + h))
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: Menu

    private func buildMenu() {
        hideThermalPopover()
        menu.removeAllItems()

        let speedView = SpeedStatusRowView(speedStatusTitle(for: latest))
        speedStatusView = speedView
        speedStatusItem = NSMenuItem()
        speedStatusItem.view = speedView
        menu.addItem(speedStatusItem)
        menu.addItem(.separator())

        let statsItem = NSMenuItem()
        statsItem.view = statsView
        menu.addItem(statsItem)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: appText("설정…", "Settings…"),
                                  action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let activity = NSMenuItem(title: appText("활성 상태 보기 열기", "Open Activity Monitor"),
                                  action: #selector(openActivityMonitor), keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)
        updateItem = NSMenuItem(title: appText("업데이트 확인", "Check for Updates"),
                                action: #selector(updateItemClicked), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        if updateCheckInFlight {
            updateItem.title = appText("업데이트 확인 중…", "Checking for Updates…")
            updateItem.action = nil
        } else if let availableUpdate {
            setUpdateAvailable(availableUpdate)
        }
        let about = NSMenuItem(title: appText("바쁘냥 정보…", "About BusyCat…"),
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: appText("바쁘냥 종료", "Quit BusyCat"),
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        statusItem.menu = menu
    }

    private func showThermalPopover(relativeTo rect: NSRect) {
        guard menuOpen else { return }
        if thermalPopover?.isShown == true { return }
        let popover: NSPopover
        if let existing = thermalPopover {
            popover = existing
        } else {
            popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSViewController()
            thermalPopover = popover
        }
        if thermalPopoverDirty {
            popover.contentViewController?.view = thermalPopoverView(for: latest)
            thermalPopoverDirty = false
        }
        popover.show(relativeTo: rect, of: statsView, preferredEdge: .maxX)
    }

    private func hideThermalPopover() {
        thermalPopover?.close()
    }

    private func thermalPopoverView(for m: Metrics) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        func row(_ title: String, secondary: Bool = false) -> NSTextField {
            let field = NSTextField(labelWithString: title)
            field.font = secondary ? .systemFont(ofSize: 11) : .systemFont(ofSize: 12)
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
            return field
        }

        stack.addArrangedSubview(row("\(appText("최고 센서", "Hottest sensor")): \(temp(m.thermalTemp))"))
        stack.addArrangedSubview(row("\(appText("열 압박", "Thermal pressure")): \(thermalState(m.thermalState))"))
        if let cpu = m.thermalCPUTemp { stack.addArrangedSubview(row("\(appText("CPU 클러스터", "CPU cluster")): \(temp(cpu))")) }
        if let battery = m.batTemp { stack.addArrangedSubview(row("\(appText("배터리", "Battery")): \(temp(battery))")) }
        if let limit = m.cpuSpeedLimit { stack.addArrangedSubview(row("\(appText("CPU 속도 제한", "CPU speed limit")): \(limit)%")) }
        if let limit = m.cpuSchedulerLimit { stack.addArrangedSubview(row("\(appText("스케줄러 제한", "Scheduler limit")): \(limit)%")) }
        if let cpus = m.cpuAvailableCPUs { stack.addArrangedSubview(row("\(appText("사용 가능 CPU", "Available CPUs")): \(cpus)")) }
        stack.addArrangedSubview(row("\(appText("읽은 온도 채널", "Temperature channels")): \(countText(m.thermalSensorCount, "개", "channel", "channels"))"))

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(separator)
        stack.addArrangedSubview(row(appText("가장 높은 센서", "Hottest sensors"), secondary: true))

        if m.thermalTopSensors.isEmpty {
            stack.addArrangedSubview(row(appText("읽힌 온도 센서 없음", "No temperature sensors read")))
        } else {
            for sensor in m.thermalTopSensors.prefix(10) {
                stack.addArrangedSubview(row("\(sensor.name) · \(sensor.source): \(temp(sensor.value))"))
            }
        }
        return stack
    }

    // MARK: Settings

    @objc private func showSettings() {
        settingsPanel?.close()
        settingsPanel = buildSettingsPanel()
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel?.center()
        settingsPanel?.makeKeyAndOrderFront(nil)
    }

    private func showFirstLaunchHintIfNeeded() {
        let key = "didShowMenuBarHint"
        guard !defaults.bool(forKey: key), let button = statusItem.button else { return }
        defaults.set(true, forKey: key)

        let label = NSTextField(wrappingLabelWithString: appText(
            "바쁘냥이 메뉴바에서 실행 중입니다.\n고양이를 누르면 상세 정보와 설정이 열립니다.",
            "BusyCat is running in your menu bar.\nClick the cat for details and settings."))
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 70))
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = content.frame.size
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = content
        firstLaunchPopover = popover
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak button] in
            guard let self, let button, !self.menuOpen,
                  self.firstLaunchPopover === popover else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak popover] in
            popover?.close()
            if self?.firstLaunchPopover === popover { self?.firstLaunchPopover = nil }
        }
    }

    private func buildSettingsPanel() -> NSPanel {
        let contentSize = NSSize(width: 420, height: 455)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        panel.title = appText("바쁘냥 설정", "BusyCat Settings")
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = contentSize
        panel.contentMaxSize = contentSize

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18)
        ])

        stack.addArrangedSubview(settingsHeader(appText("메뉴바", "Menu Bar")))
        stack.addArrangedSubview(settingsRow(appText("표시", "Display"), popUp(
            items: StatusTextMode.allCases.map { ($0.label, $0.rawValue) },
            selected: statusTextMode.rawValue,
            action: #selector(settingsStatusTextChanged(_:)))))
        stack.addArrangedSubview(checkBox(appText("메모리 압력 생선 표시", "Memory pressure fish"), checked: memoryFish,
                                          action: #selector(settingsMemoryFishChanged(_:))))

        stack.addArrangedSubview(settingsGap())
        stack.addArrangedSubview(settingsHeader(appText("속도", "Speed")))
        stack.addArrangedSubview(settingsRow(appText("속도 기준", "Speed source"), popUp(
            items: SpeedDriver.allCases.map { ($0.label, $0.rawValue) },
            selected: driver.rawValue,
            action: #selector(settingsDriverChanged(_:)))))
        stack.addArrangedSubview(checkBox(appText("속도 반전 (바쁘면 느리게)", "Invert speed (busier = slower)"), checked: invert,
                                          action: #selector(settingsInvertChanged(_:))))

        stack.addArrangedSubview(settingsGap())
        stack.addArrangedSubview(settingsHeader(appText("디자인", "Design")))
        stack.addArrangedSubview(settingsRow(appText("고양이 색", "Cat color"), popUp(
            items: CatColor.allCases.map { ($0.label, $0.rawValue) },
            selected: catColor.rawValue,
            action: #selector(settingsCatColorChanged(_:)))))
        stack.addArrangedSubview(settingsRow(appText("그래프/바 색", "Graph/bar color"), popUp(
            items: MeterColor.allCases.map { ($0.label, $0.rawValue) },
            selected: meterColor.rawValue,
            action: #selector(settingsMeterColorChanged(_:)))))
        stack.addArrangedSubview(checkBox(appText("좌우 반전", "Flip direction"), checked: flip,
                                          action: #selector(settingsFlipChanged(_:))))
        stack.addArrangedSubview(checkBox(appText("열 압박 시 빨간 테두리", "Red outline on thermal pressure"), checked: thermalCatTint,
                                          action: #selector(settingsThermalCatChanged(_:))))

        stack.addArrangedSubview(settingsGap())
        stack.addArrangedSubview(settingsHeader(appText("시스템", "System")))
        stack.addArrangedSubview(settingsRow(appText("언어", "Language"), popUp(
            items: AppLanguage.allCases.map { ($0.label, $0.rawValue) },
            selected: language.rawValue,
            action: #selector(settingsLanguageChanged(_:)))))
        stack.addArrangedSubview(checkBox(appText("로그인 시 자동 실행", "Launch at login"), checked: isLoginEnabled(),
                                          action: #selector(settingsLoginChanged(_:))))

        return panel
    }

    private func settingsHeader(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = .labelColor
        return field
    }

    private func settingsGap() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 4).isActive = true
        return view
    }

    private func settingsRow(_ label: String, _ control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let labelView = NSTextField(labelWithString: label)
        labelView.textColor = .secondaryLabelColor
        labelView.widthAnchor.constraint(equalToConstant: 104).isActive = true
        row.addArrangedSubview(labelView)
        row.addArrangedSubview(control)
        return row
    }

    private func popUp(items: [(String, String)], selected: String, action: Selector) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        for item in items {
            button.addItem(withTitle: item.0)
            button.lastItem?.representedObject = item.1
        }
        if let index = items.firstIndex(where: { $0.1 == selected }) {
            button.selectItem(at: index)
        }
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 210).isActive = true
        return button
    }

    private func checkBox(_ title: String, checked: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = checked ? .on : .off
        return button
    }

    // MARK: Sampling + animation

    private func requestSample(full requestedFull: Bool? = nil) {
        guard !asleep else { return }
        let full = requestedFull ?? menuOpen
        if samplingInFlight {
            if full { fullSamplePending = true }
            return
        }

        samplingInFlight = true
        sampling.sample(full: full, includeTemperature: statusTextMode == .temperature) { [weak self] sample in
            guard let self else { return }
            self.samplingInFlight = false
            self.applySample(sample, full: full)
            if self.fullSamplePending {
                self.fullSamplePending = false
                if self.menuOpen { self.requestSample(full: true) }
            }
        }
    }

    private func applySample(_ sample: Metrics, full: Bool) {
        if full {
            latest = sample
            thermalPopoverDirty = true
        } else {
            latest.cpu = sample.cpu
            latest.cpuSystem = sample.cpuSystem
            latest.cpuUser = sample.cpuUser
            latest.gpuCompute = sample.gpuCompute
            latest.gpuRaw = sample.gpuRaw
            latest.gpuRender = sample.gpuRender
            latest.gpuAvailable = sample.gpuAvailable
            latest.memory = sample.memory
            latest.memoryPressure = sample.memoryPressure
            latest.memApp = sample.memApp
            latest.memWired = sample.memWired
            latest.memCompressed = sample.memCompressed
            latest.thermalState = sample.thermalState
            if statusTextMode == .temperature {
                latest.thermalTemp = sample.thermalTemp
            }
        }

        cpuHistory.append(latest.cpu)
        if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        updateStatusAccessibility()
        refreshPresentation()
    }

    private func refreshPresentation() {
        if menuOpen {
            statsView.update(latest, history: cpuHistory, meterColor: meterColor.color)
            updateSpeedStatusItem()
        }
        if catTintKey() != lastTintKey { rebuildArtwork() }
        if statusTextMode != .off { layout() }
        if memoryFish { updateFishPile() }

        guard !asleep else { return }
        let usage = effectiveSpeedUsage(latest)
        let thermal = ProcessInfo.ThermalState(rawValue: latest.thermalState) ?? .nominal
        let maximumFPS: Double
        switch thermal {
        case .serious, .critical:
            maximumFPS = 20
        case .fair:
            maximumFPS = 30
        case .nominal:
            maximumFPS = ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 50
        @unknown default:
            maximumFPS = 30
        }
        let target = SpeedCurve.interval(forUsage: usage, maximumFPS: maximumFPS)
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

    private func statusText(for m: Metrics) -> String? {
        switch statusTextMode {
        case .off:
            return nil
        case .driver:
            return String(format: "%.0f%%", effectiveSpeedUsage(m))
        case .cpu:
            return String(format: "CPU %.0f%%", m.cpu)
        case .gpu:
            return m.gpuAvailable
                ? String(format: appText("GPU 연산 %.0f%%", "GPU compute %.0f%%"), m.gpuCompute)
                : appText("GPU 연산 —", "GPU compute —")
        case .memory:
            return String(format: "RAM %.0f%%", m.memory)
        case .temperature:
            return m.thermalTemp.map { String(format: "%.0f°C", $0) } ?? appText("온도 —", "Temp —")
        case .thermal:
            return thermalState(m.thermalState)
        }
    }

    private func speedShortLabel(for m: Metrics) -> String {
        switch driver {
        case .busiest:
            return m.gpuAvailable && m.gpuCompute > m.cpu ? appText("GPU 연산", "GPU compute") : "CPU"
        case .cpu:
            return "CPU"
        case .gpu:
            return m.gpuAvailable ? appText("GPU 연산", "GPU compute") : appText("GPU 사용 불가", "GPU unavailable")
        case .memory:
            return appText("메모리", "Memory")
        }
    }

    private func effectiveSpeedUsage(_ m: Metrics) -> Double {
        MetricMath.speedUsage(base: driver.value(m), inverted: invert)
    }

    private func updateSpeedStatusItem() {
        speedStatusView?.update(speedStatusTitle(for: latest))
    }

    private func speedStatusTitle(for m: Metrics) -> String {
        "\(appText("속도 기준", "Speed source")): \(speedShortLabel(for: m))"
    }

    private func temp(_ value: Double?) -> String {
        value.map { String(format: "%.1f°C", $0) } ?? "—"
    }

    private func thermalState(_ raw: Int) -> String {
        switch ProcessInfo.ThermalState(rawValue: raw) {
        case .nominal: return appText("정상", "Nominal")
        case .fair: return appText("약간 높음", "Fair")
        case .serious: return appText("높음", "Serious")
        case .critical: return appText("위험", "Critical")
        default: return "—"
        }
    }

    private func memoryPressureText(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: return appText("정상", "Normal")
        case .warning: return appText("주의", "Warning")
        case .critical: return appText("위험", "Critical")
        }
    }

    private func updateStatusAccessibility() {
        guard let button = statusItem.button else { return }
        let gpuValue = latest.gpuAvailable
            ? String(format: appText("GPU 연산 %.0f%%", "GPU compute %.0f%%"), latest.gpuCompute)
            : appText("GPU 사용 불가", "GPU unavailable")
        button.toolTip = appText("바쁘냥 시스템 상태", "BusyCat system status")
        button.setAccessibilityLabel(appText("바쁘냥 시스템 모니터", "BusyCat system monitor"))
        button.setAccessibilityHelp(appText(
            "누르면 CPU, GPU 연산, 메모리와 온도 상세 정보를 엽니다.",
            "Press to open CPU, GPU compute, memory, and temperature details."))
        button.setAccessibilityValue(String(format: appText(
            "CPU %.0f%%, %@, 메모리 %.0f%%, 메모리 압력 %@",
            "CPU %.0f%%, %@, memory %.0f%%, memory pressure %@"),
            latest.cpu, gpuValue, latest.memory,
            memoryPressureText(latest.memoryPressure)))
    }

    // MARK: Actions

    private func applyDriver(_ d: SpeedDriver) {
        driver = d
        updateSpeedStatusItem()
        refreshPresentation()
    }

    private func applyCatColor(_ c: CatColor) {
        catColor = c
        rebuildArtwork()
        if memoryFish { updateFishPile() }
    }

    private func applyMeterColor(_ c: MeterColor) {
        meterColor = c
        if menuOpen {
            statsView.update(latest, history: cpuHistory, meterColor: c.color)
        }
    }

    private func applyStatusTextMode(_ mode: StatusTextMode) {
        statusTextMode = mode
        layout()
        refreshPresentation()
        if mode == .temperature { requestSample() }
    }

    private func applyLanguage(_ lang: AppLanguage) {
        language = lang
        buildMenu()
        layout()
        refreshPresentation()
        updateStatusAccessibility()
        if settingsPanel?.isVisible == true {
            settingsPanel?.close()
            settingsPanel = buildSettingsPanel()
            settingsPanel?.center()
            settingsPanel?.makeKeyAndOrderFront(nil)
        }
    }

    private func applyMemoryFish(_ on: Bool) {
        memoryFish = on
        lastFishLevel = -1
        layout()
        updateFishPile()
    }

    private func applyInvert(_ on: Bool) {
        invert = on
        refreshPresentation()
    }

    private func applyFlip(_ on: Bool) {
        flip = on
        rebuildArtwork()
    }

    private func applyThermalCatTint(_ on: Bool) {
        thermalCatTint = on
        rebuildArtwork()
    }

    private func applyLogin(_ on: Bool) {
        setLogin(on)
    }

    private func selectedRaw(_ sender: NSPopUpButton) -> String? {
        sender.selectedItem?.representedObject as? String
    }

    @objc private func settingsStatusTextChanged(_ sender: NSPopUpButton) {
        guard let raw = selectedRaw(sender), let mode = StatusTextMode(rawValue: raw) else { return }
        applyStatusTextMode(mode)
    }

    @objc private func settingsLanguageChanged(_ sender: NSPopUpButton) {
        guard let raw = selectedRaw(sender), let lang = AppLanguage(rawValue: raw) else { return }
        applyLanguage(lang)
    }

    @objc private func settingsDriverChanged(_ sender: NSPopUpButton) {
        guard let raw = selectedRaw(sender), let d = SpeedDriver(rawValue: raw) else { return }
        applyDriver(d)
    }

    @objc private func settingsCatColorChanged(_ sender: NSPopUpButton) {
        guard let raw = selectedRaw(sender), let c = CatColor(rawValue: raw) else { return }
        applyCatColor(c)
    }

    @objc private func settingsMeterColorChanged(_ sender: NSPopUpButton) {
        guard let raw = selectedRaw(sender), let c = MeterColor(rawValue: raw) else { return }
        applyMeterColor(c)
    }

    @objc private func settingsMemoryFishChanged(_ sender: NSButton) {
        applyMemoryFish(sender.state == .on)
    }

    @objc private func settingsInvertChanged(_ sender: NSButton) {
        applyInvert(sender.state == .on)
    }

    @objc private func settingsFlipChanged(_ sender: NSButton) {
        applyFlip(sender.state == .on)
    }

    @objc private func settingsThermalCatChanged(_ sender: NSButton) {
        applyThermalCatTint(sender.state == .on)
    }

    @objc private func settingsLoginChanged(_ sender: NSButton) {
        applyLogin(sender.state == .on)
        sender.state = isLoginEnabled() ? .on : .off
    }

    @objc private func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appText("바쁘냥", "BusyCat"),
            .applicationVersion: "v\(Updater.currentVersion)",
            .credits: NSAttributedString(string: appText(
                "Apple Silicon용 오픈소스 메뉴바 시스템 모니터",
                "Open-source menu bar system monitor for Apple Silicon"))
        ])
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
        guard !updateCheckInFlight else { return }
        updateCheckInFlight = true
        updateItem.title = appText("업데이트 확인 중…", "Checking for Updates…")
        updateItem.action = nil
        Updater.check { [weak self] result in
            guard let self else { return }
            self.updateCheckInFlight = false
            switch result {
            case .updateAvailable(let v):
                self.setUpdateAvailable(v)
                NSWorkspace.shared.open(Updater.releasesPage)
            case .upToDate:
                self.updateItem.title = appText("업데이트 확인", "Check for Updates")
                self.updateItem.action = #selector(self.updateItemClicked)
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = appText("최신 버전입니다", "You're up to date")
                a.informativeText = appText(
                    "현재 v\(Updater.currentVersion)이 최신입니다.",
                    "Current v\(Updater.currentVersion) is the latest.")
                a.runModal()
            case .failed:
                self.updateItem.title = appText("업데이트 확인", "Check for Updates")
                self.updateItem.action = #selector(self.updateItemClicked)
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = appText("업데이트를 확인할 수 없습니다", "Couldn't check for updates")
                a.informativeText = appText(
                    "네트워크 연결을 확인한 뒤 다시 시도해 주세요.",
                    "Check your network connection and try again.")
                a.runModal()
            }
        }
    }

    private func setUpdateAvailable(_ v: String) {
        availableUpdate = v
        updateItem.title = appText("🆕 새 버전 v\(v) 받기", "🆕 Get v\(v)")
        updateItem.action = #selector(updateItemClicked)
        updateItem.target = self
    }

    /// Quiet background check: once per day after success, and no more than once
    /// per hour after a transient failure during the current app session.
    private func maybeAutoCheckUpdate() {
        let key = "lastUpdateCheck"
        let attempt = Date()
        let now = attempt.timeIntervalSince1970
        guard !updateCheckInFlight,
              attempt.timeIntervalSince(lastUpdateAttempt) > 3600,
              now - defaults.double(forKey: key) > 24 * 3600 else { return }
        lastUpdateAttempt = attempt
        updateCheckInFlight = true
        Updater.check { [weak self] result in
            guard let self else { return }
            self.updateCheckInFlight = false
            switch result {
            case .updateAvailable(let v):
                self.defaults.set(now, forKey: key)
                self.setUpdateAvailable(v)
            case .upToDate:
                self.defaults.set(now, forKey: key)
            case .failed:
                break // retry after an hour, or once on the next launch
            }
        }
    }

    private func startUpdateSchedule() {
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.maybeAutoCheckUpdate()
        }
        timer.tolerance = 30 * 60
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
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
            } catch {
                NSLog("BusyCat login item error: \(error)")
                showAlert(
                    message: appText("로그인 항목을 변경하지 못했습니다", "Couldn't change the login item"),
                    information: appText(
                        "시스템 설정 → 일반 → 로그인 항목에서 바쁘냥 권한을 확인해 주세요.\n\n\(error.localizedDescription)",
                        "Check BusyCat under System Settings → General → Login Items.\n\n\(error.localizedDescription)"),
                    style: .warning)
                return
            }
            if on, SMAppService.mainApp.status == .requiresApproval {
                showAlert(
                    message: appText("로그인 항목 승인이 필요합니다", "Login item approval required"),
                    information: appText(
                        "시스템 설정 → 일반 → 로그인 항목에서 바쁘냥을 허용해 주세요.",
                        "Allow BusyCat under System Settings → General → Login Items."),
                    style: .informational)
            }
        }
    }

    private func showAlert(message: String, information: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = information
        alert.runModal()
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
        sampling.resetFastHistory()
        startAnimation(interval: currentInterval)
        requestSample(full: menuOpen)
        maybeAutoCheckUpdate()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        statsView.update(latest, history: cpuHistory, meterColor: meterColor.color)
        updateSpeedStatusItem()
        maybeAutoCheckUpdate()
        requestSample(full: true)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        fullSamplePending = false
        hideThermalPopover()
        statsView.resetThermalHover()
    }
}
