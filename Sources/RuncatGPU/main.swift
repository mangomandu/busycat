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

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
