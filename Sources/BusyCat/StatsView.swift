import AppKit

/// Full-custom stats panel shown as the top item of the menu (RunCat-style):
/// per metric an SF Symbol icon, a big title, indented sub-rows, and a small
/// graph (CPU sparkline / storage bar). Drawn entirely in `draw(_:)` so it's one
/// lightweight view that only renders while the menu is open — zero idle cost.
final class StatsView: NSView {
    private var metrics = Metrics()
    private var cpuHistory: [Double] = []
    private var meterTint = NSColor.systemGray

    private let panelWidth: CGFloat = 250
    private let iconX: CGFloat = 18
    private let iconSize: CGFloat = 24
    private let textX: CGFloat = 56
    private let padX: CGFloat = 16
    private let meterWidth: CGFloat = 150
    private let padTop: CGFloat = 12
    private let padBottom: CGFloat = 10
    private let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private let subFont = NSFont.systemFont(ofSize: 11)
    private let titleH: CGFloat = 22
    private let subH: CGFloat = 15
    private let graphH: CGFloat = 20
    private let sectionGap: CGFloat = 12

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 100))
        resize()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var cachedSections: [Section] = []

    func update(_ m: Metrics, history: [Double], meterColor: NSColor? = nil) {
        metrics = m
        cpuHistory = history
        if let meterColor { meterTint = meterColor }
        cachedSections = sections()   // build once per update, reused by resize()+draw()
        resize()
        needsDisplay = true
    }

    // MARK: Section model

    private enum Graph { case none, spark, bar }
    private struct Section {
        let symbols: [String]
        let title: String
        let titleValue: String?
        let subs: [String]
        let graph: Graph
        let accent: NSColor?
    }

    private func section(_ symbols: [String], _ title: String, subs: [String], _ graph: Graph,
                         accent: NSColor? = nil, titleValue: String? = nil) -> Section {
        Section(symbols: symbols, title: title, titleValue: titleValue,
                subs: subs, graph: graph, accent: accent)
    }

    private func sections() -> [Section] {
        let m = metrics
        func p1(_ v: Double) -> String { String(format: "%.1f%%", v) }
        func p0(_ v: Double) -> String { String(format: "%.0f%%", v) }
        func gb(_ b: Double) -> String { String(format: "%.1f GB", b / 1_000_000_000) }
        func mem(_ b: Double) -> String {
            b >= 1_000_000_000 ? String(format: "%.1f GB", b / 1e9) : String(format: "%.1f MB", b / 1e6)
        }
        func rate(_ b: Double) -> String {
            if b >= 1_000_000 { return String(format: "%.1f MB/s", b / 1e6) }
            if b >= 1_000 { return String(format: "%.1f kB/s", b / 1e3) }
            return String(format: "%.0f byte/s", b)
        }
        func thermalState(_ raw: Int) -> String {
            switch ProcessInfo.ThermalState(rawValue: raw) {
            case .nominal: return "정상"
            case .fair: return "약간 높음"
            case .serious: return "높음"
            case .critical: return "위험"
            default: return "—"
            }
        }
        func temp(_ value: Double?) -> String {
            value.map { String(format: "%.1f°C", $0) } ?? "—"
        }
        func thermalAccent(state: Int, speedLimit: Int?) -> NSColor? {
            if let speedLimit, speedLimit > 0, speedLimit < 60 { return .systemOrange }
            if ProcessInfo.ThermalState(rawValue: state) != .nominal { return .systemOrange }
            return nil
        }

        let thermalAccent = thermalAccent(state: m.thermalState, speedLimit: m.cpuSpeedLimit)
        var thermalSubs = [
            "최고 센서: \(temp(m.thermalTemp))",
        ]
        if let speedLimit = m.cpuSpeedLimit, speedLimit > 0, speedLimit < 100 {
            thermalSubs.append("CPU 속도 제한: \(speedLimit)%")
        }
        if let schedulerLimit = m.cpuSchedulerLimit, schedulerLimit > 0, schedulerLimit < 100 {
            thermalSubs.append("스케줄러 제한: \(schedulerLimit)%")
        }

        var list: [Section] = [
            section(["cpu"], "CPU: \(p1(m.cpu))",
                    subs: ["시스템: \(p1(m.cpuSystem))", "사용자: \(p1(m.cpuUser))",
                           "대기: \(p1(max(0, 100 - m.cpu)))"], .spark),
            section(["gpucard", "cpu.fill"], "GPU: \(p0(m.gpuRaw))",
                    subs: ["화면 합성: \(p0(m.gpuRender))", "속도 반영: \(p1(m.gpu))"], .none),
            section(["memorychip"], "메모리: \(p1(m.memory))",
                    subs: ["압력: \(p1(m.memPressure))", "앱 메모리: \(gb(m.memApp))",
                           "와이어드 메모리: \(gb(m.memWired))", "압축됨: \(mem(m.memCompressed))"], .none),
            section(["internaldrive"], "저장 용량: \(p1(m.disk)) 사용됨",
                    subs: ["\(gb(m.diskUsed)) / \(gb(m.diskTotal))"], .bar),
            section(["thermometer.medium", "thermometer"],
                    "열 압박:", subs: thermalSubs, .none,
                    accent: thermalAccent, titleValue: thermalState(m.thermalState)),
        ]
        if let b = m.battery {
            list.append(section(m.charging ? ["battery.100.bolt", "battery.100"] : ["battery.100"],
                "배터리: \(String(format: "%.0f%%", b))",
                subs: ["전원 공급원: \(m.onAC ? "전원 어댑터" : "배터리")",
                       "성능 최대치: \(m.batHealth.map { String(format: "%.1f%%", $0) } ?? "—")",
                       "사이클 수: \(m.batCycles.map(String.init) ?? "—")",
                       "온도: \(m.batTemp.map { String(format: "%.1f°C", $0) } ?? "—")"], .none))
        }
        list.append(section(["wifi", "network"], "네트워크: \(m.netType)",
            subs: ["로컬 IP: \(m.localIP)", "업로드: \(rate(m.netUp))", "다운로드: \(rate(m.netDown))"],
            .none))
        return list
    }

    private func sectionHeight(_ s: Section) -> CGFloat {
        titleH + CGFloat(s.subs.count) * subH + (s.graph == .none ? 0 : graphH + 4)
    }

    private func resize() {
        let secs = cachedSections.isEmpty ? sections() : cachedSections
        let h = padTop + padBottom
            + secs.map(sectionHeight).reduce(0, +)
            + CGFloat(max(0, secs.count - 1)) * sectionGap
        setFrameSize(NSSize(width: panelWidth, height: h))
    }

    override var intrinsicContentSize: NSSize { frame.size }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let secs = cachedSections.isEmpty ? sections() : cachedSections
        var y = padTop
        for (i, s) in secs.enumerated() {
            let top = y
            drawTitle(s, at: NSPoint(x: textX, y: y))
            y += titleH
            for sub in s.subs {
                (sub as NSString).draw(at: NSPoint(x: textX, y: y),
                    withAttributes: [.font: subFont, .foregroundColor: NSColor.secondaryLabelColor])
                y += subH
            }
            if s.graph != .none {
                let r = NSRect(x: textX, y: y + 2,
                               width: min(meterWidth, panelWidth - textX - padX),
                               height: graphH)
                if s.graph == .spark { drawSpark(in: r) } else { drawBar(in: r, fraction: metrics.disk / 100) }
                y += graphH + 4
            }
            drawIcon(s.symbols, centerY: (top + y) / 2, color: s.accent ?? NSColor.secondaryLabelColor)
            y += sectionGap
            if i < secs.count - 1 {
                NSColor.separatorColor.setStroke()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: padX, y: y - sectionGap / 2))
                line.line(to: NSPoint(x: panelWidth - padX, y: y - sectionGap / 2))
                line.lineWidth = 1
                line.stroke()
            }
        }
    }

    private func drawTitle(_ section: Section, at point: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: NSColor.labelColor]
        (section.title as NSString).draw(at: point, withAttributes: attrs)
        guard let value = section.titleValue else { return }
        let x = point.x + (section.title as NSString).size(withAttributes: attrs).width + 4
        (value as NSString).draw(at: NSPoint(x: x, y: point.y),
            withAttributes: [.font: titleFont, .foregroundColor: section.accent ?? NSColor.labelColor])
    }

    // Tinted SF Symbols are static given the appearance, so cache them instead of
    // re-loading + re-rendering all icons on every draw. Invalidated on dark/light.
    private var iconCache: [String: NSImage] = [:]
    private var iconAppearance: NSAppearance.Name?

    private func tintedIcon(_ names: [String], color: NSColor) -> NSImage? {
        let appName = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        if appName != iconAppearance { iconCache.removeAll(); iconAppearance = appName }
        let key = names.joined(separator: "|") + "|\(color.description)"
        if let cached = iconCache[key] { return cached }
        let cfg = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
        guard let base = names.lazy
            .compactMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) })
            .first?.withSymbolConfiguration(cfg) else { return nil }
        let tinted = NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            color.setFill()
            r.fill(using: .sourceAtop)
            return true
        }
        iconCache[key] = tinted
        return tinted
    }

    private func drawIcon(_ names: [String], centerY: CGFloat, color: NSColor) {
        guard let img = tintedIcon(names, color: color) else { return }
        let s = img.size
        let scale = min(1, iconSize / max(s.width, s.height))
        let w = s.width * scale, h = s.height * scale
        img.draw(in: NSRect(x: iconX + (iconSize - w) / 2, y: centerY - h / 2, width: w, height: h))
    }

    private func drawBar(in rect: NSRect, fraction: Double) {
        let h: CGFloat = 9
        let barRect = NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
        let radius = h / 2
        let track = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)
        meterColor.withAlphaComponent(0.18).setFill()
        track.fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        track.lineWidth = 1
        track.stroke()
        let f = max(0, min(1, fraction))
        if f > 0 {
            NSGraphicsContext.saveGraphicsState()
            track.addClip()
            let fill = NSRect(x: barRect.minX, y: barRect.minY, width: barRect.width * f, height: barRect.height)
            meterColor.setFill()
            fill.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawSpark(in rect: NSRect) {
        guard cpuHistory.count >= 2 else { return }
        let maxV = max(20.0, cpuHistory.max() ?? 1)  // floor so a flat-low line isn't full height
        let n = cpuHistory.count
        var points: [NSPoint] = []
        let path = NSBezierPath()
        for (i, v) in cpuHistory.enumerated() {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(n - 1)
            let yv = rect.maxY - rect.height * CGFloat(v / maxV)  // flipped: higher v → nearer top
            let pt = NSPoint(x: x, y: yv)
            points.append(pt)
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }

        if let first = points.first, let last = points.last {
            let fill = NSBezierPath()
            fill.move(to: NSPoint(x: first.x, y: rect.maxY))
            fill.line(to: first)
            for pt in points.dropFirst() { fill.line(to: pt) }
            fill.line(to: NSPoint(x: last.x, y: rect.maxY))
            fill.close()
            meterColor.withAlphaComponent(0.10).setFill()
            fill.fill()
        }

        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: rect.minX, y: rect.maxY - 0.5))
        baseline.line(to: NSPoint(x: rect.maxX, y: rect.maxY - 0.5))
        baseline.lineWidth = 1
        baseline.stroke()

        meterColor.setStroke()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private var meterColor: NSColor {
        meterTint
    }
}
