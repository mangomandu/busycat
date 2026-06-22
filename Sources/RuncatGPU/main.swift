import Cocoa

// Debug: `RuncatGPU --metrics` prints one sample (after a 1s priming gap) and
// exits, without launching the menu bar app.
if CommandLine.arguments.contains("--metrics") {
    let s = SystemSampler()
    _ = s.sampleAll()
    Thread.sleep(forTimeInterval: 1.0)
    let m = s.sampleAll()
    print(String(format: "CPU=%.1f%% (sys %.1f / usr %.1f)",
                 m.cpu, m.cpuSystem, m.cpuUser))
    print(String(format: "GPU compute=%.1f%%  raw=%.0f%%  render=%.0f%%",
                 m.gpu, m.gpuRaw, m.gpuRender))
    print(String(format: "MEM=%.1f%%  DISK=%.1f%%  NET ↓%.0fB/s ↑%.0fB/s  BAT=%@",
                 m.memory, m.disk, m.netDown, m.netUp, m.battery.map { "\($0)%" } ?? "n/a"))
    exit(0)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
