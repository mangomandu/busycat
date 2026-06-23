import Cocoa

// Debug: `RuncatGPU --metrics` prints one sample (after a 1s priming gap) and
// exits, without launching the menu bar app.
if CommandLine.arguments.contains("--metrics") {
    let s = SystemSampler()
    _ = s.sampleAll()
    Thread.sleep(forTimeInterval: 1.0)
    let m = s.sampleAll()
    print(String(format: "CPU=%.1f%% (sys %.1f / usr %.1f / idle %.1f)",
                 m.cpu, m.cpuSystem, m.cpuUser, max(0, 100 - m.cpu)))
    print(String(format: "GPU compute=%.1f%%  raw=%.0f%%  render=%.0f%%",
                 m.gpu, m.gpuRaw, m.gpuRender))
    print(String(format: "MEM=%.1f%%  press=%.1f%%  app=%.1fGB wired=%.1fGB comp=%.0fMB",
                 m.memory, m.memPressure, m.memApp / 1e9, m.memWired / 1e9, m.memCompressed / 1e6))
    print(String(format: "DISK=%.1f%%  %.1f/%.1f GB", m.disk, m.diskUsed / 1e9, m.diskTotal / 1e9))
    print(String(format: "NET %@  ip=%@  ↓%.0fB/s ↑%.0fB/s",
                 m.netType, m.localIP, m.netDown, m.netUp))
    print("BAT=\(m.battery.map { String(format: "%.1f%%", $0) } ?? "n/a")  "
          + "AC=\(m.onAC)  health=\(m.batHealth.map { String(format: "%.1f%%", $0) } ?? "—")  "
          + "cycles=\(m.batCycles.map(String.init) ?? "—")  "
          + "temp=\(m.batTemp.map { String(format: "%.1f°C", $0) } ?? "—")")
    exit(0)
}

// Debug: render the custom stats panel to a PNG (on a menu-like dark bg) so the
// layout can be eyeballed without opening the live menu.
if CommandLine.arguments.contains("--statsdump") {
    var m = Metrics()
    m.cpu = 5.6; m.cpuSystem = 2.9; m.cpuUser = 2.7
    m.gpu = 0; m.gpuRaw = 0; m.gpuRender = 0
    m.memory = 40.5; m.memPressure = 6.2
    m.memApp = 17.7e9; m.memWired = 2.8e9; m.memCompressed = 323.7e6
    m.disk = 10.4; m.diskUsed = 103.6e9; m.diskTotal = 994.6e9
    m.battery = 99; m.onAC = false; m.charging = false
    m.batHealth = 100; m.batCycles = 3; m.batTemp = 30.1
    m.netType = "Wi-Fi"; m.localIP = "192.168.0.2"; m.netUp = 819; m.netDown = 409
    let v = StatsView()
    v.update(m, history: (0..<60).map { 20 + 18 * sin(Double($0) / 4) })
    let size = v.frame.size
    let img = NSImage(size: size, flipped: true) { rect in
        NSColor(white: 0.20, alpha: 1).setFill(); rect.fill()
        v.draw(rect)
        return true
    }
    if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "/tmp/stats.png"))
        print("wrote /tmp/stats.png \(size)")
    }
    exit(0)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
