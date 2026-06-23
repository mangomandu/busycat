import AppKit

/// Full-custom stats panel shown as the top item of the menu (RunCat-style):
/// per metric an SF Symbol icon, a big title, indented sub-rows, and a small
/// graph (CPU sparkline / storage bar). Drawn entirely in `draw(_:)` so it's one
/// lightweight view that only renders while the menu is open — zero idle cost.
final class StatsView: NSView {
    private var metrics = Metrics()
    private var cpuHistory: [Double] = []

    private let panelWidth: CGFloat = 300
    private let iconX: CGFloat = 18
    private let iconSize: CGFloat = 24
    private let textX: CGFloat = 56
    private let padX: CGFloat = 16
    private let padTop: CGFloat = 12
    private let padBottom: CGFloat = 10
    private let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private let subFont = NSFont.systemFont(ofSize: 11)
    private let titleH: CGFloat = 22
    private let subH: CGFloat = 15
    private let graphH: CGFloat = 16
    private let sectionGap: CGFloat = 12

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        resize()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var cachedSections: [Section] = []

    func update(_ m: Metrics, history: [Double]) {
        metrics = m
        cpuHistory = history
        cachedSections = sections()   // build once per update, reused by resize()+draw()
        resize()
        needsDisplay = true
    }

    // MARK: Section model

    private enum Graph { case none, spark, bar }
    private struct Section { let symbols: [String]; let title: String; let subs: [String]; let graph: Graph }

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

        var list: [Section] = [
            Section(symbols: ["cpu"], title: "CPU: \(p1(m.cpu))",
                    subs: ["시스템: \(p1(m.cpuSystem))", "사용자: \(p1(m.cpuUser))",
                           "대기: \(p1(max(0, 100 - m.cpu)))"], graph: .spark),
            Section(symbols: ["gpucard", "cpu.fill"], title: "GPU: \(p0(m.gpuRaw))",
                    subs: ["렌더(합성): \(p0(m.gpuRender))", "연산(고양이): \(p1(m.gpu))"], graph: .none),
            Section(symbols: ["memorychip"], title: "메모리: \(p1(m.memory))",
                    subs: ["압력: \(p1(m.memPressure))", "앱 메모리: \(gb(m.memApp))",
                           "와이어드 메모리: \(gb(m.memWired))", "압축됨: \(mem(m.memCompressed))"], graph: .none),
            Section(symbols: ["internaldrive"], title: "저장 용량: \(p1(m.disk)) 사용됨",
                    subs: ["\(gb(m.diskUsed)) / \(gb(m.diskTotal))"], graph: .bar),
        ]
        if let b = m.battery {
            list.append(Section(symbols: m.charging ? ["battery.100.bolt", "battery.100"] : ["battery.100"],
                title: "배터리: \(String(format: "%.0f%%", b))",
                subs: ["전원 공급원: \(m.onAC ? "전원 어댑터" : "배터리")",
                       "성능 최대치: \(m.batHealth.map { String(format: "%.1f%%", $0) } ?? "—")",
                       "사이클 수: \(m.batCycles.map(String.init) ?? "—")",
                       "온도: \(m.batTemp.map { String(format: "%.1f°C", $0) } ?? "—")"], graph: .none))
        }
        list.append(Section(symbols: ["wifi", "network"], title: "네트워크: \(m.netType)",
            subs: ["로컬 IP: \(m.localIP)", "업로드: \(rate(m.netUp))", "다운로드: \(rate(m.netDown))"],
            graph: .none))
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
            (s.title as NSString).draw(at: NSPoint(x: textX, y: y),
                withAttributes: [.font: titleFont, .foregroundColor: NSColor.labelColor])
            y += titleH
            for sub in s.subs {
                (sub as NSString).draw(at: NSPoint(x: textX, y: y),
                    withAttributes: [.font: subFont, .foregroundColor: NSColor.secondaryLabelColor])
                y += subH
            }
            if s.graph != .none {
                let r = NSRect(x: textX, y: y + 2, width: panelWidth - textX - padX, height: graphH)
                if s.graph == .spark { drawSpark(in: r) } else { drawBar(in: r, fraction: metrics.disk / 100) }
                y += graphH + 4
            }
            drawIcon(s.symbols, centerY: (top + y) / 2)
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

    // Tinted SF Symbols are static given the appearance, so cache them instead of
    // re-loading + re-rendering all icons on every draw. Invalidated on dark/light.
    private var iconCache: [String: NSImage] = [:]
    private var iconAppearance: NSAppearance.Name?

    private func tintedIcon(_ names: [String]) -> NSImage? {
        let appName = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        if appName != iconAppearance { iconCache.removeAll(); iconAppearance = appName }
        let key = names.joined(separator: "|")
        if let cached = iconCache[key] { return cached }
        let cfg = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
        guard let base = names.lazy
            .compactMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) })
            .first?.withSymbolConfiguration(cfg) else { return nil }
        let color = NSColor.secondaryLabelColor
        let tinted = NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            color.setFill()
            r.fill(using: .sourceAtop)
            return true
        }
        iconCache[key] = tinted
        return tinted
    }

    private func drawIcon(_ names: [String], centerY: CGFloat) {
        guard let img = tintedIcon(names) else { return }
        let s = img.size
        let scale = min(1, iconSize / max(s.width, s.height))
        let w = s.width * scale, h = s.height * scale
        img.draw(in: NSRect(x: iconX + (iconSize - w) / 2, y: centerY - h / 2, width: w, height: h))
    }

    private func drawBar(in rect: NSRect, fraction: Double) {
        let track = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setFill()
        track.fill()
        let f = max(0, min(1, fraction))
        if f > 0 {
            let fill = NSRect(x: rect.minX, y: rect.minY, width: rect.width * f, height: rect.height)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }
    }

    private func drawSpark(in rect: NSRect) {
        guard cpuHistory.count >= 2 else { return }
        let maxV = max(20.0, cpuHistory.max() ?? 1)  // floor so a flat-low line isn't full height
        let n = cpuHistory.count
        let path = NSBezierPath()
        for (i, v) in cpuHistory.enumerated() {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(n - 1)
            let yv = rect.maxY - rect.height * CGFloat(v / maxV)  // flipped: higher v → nearer top
            let pt = NSPoint(x: x, y: yv)
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.stroke()
    }
}
