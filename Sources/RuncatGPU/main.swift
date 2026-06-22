import Cocoa

// Debug: `RuncatGPU --metrics` prints one sample (after a 1s priming gap) and
// exits, without launching the menu bar app.
if CommandLine.arguments.contains("--metrics") {
    let s = SystemSampler()
    _ = s.sampleAll()
    Thread.sleep(forTimeInterval: 1.0)
    let m = s.sampleAll()
    print(String(format: "CPU=%.1f%%  GPU=%.1f%%  MEM=%.1f%%  DISK=%.1f%%",
                 m.cpu, m.gpu, m.memory, m.disk))
    print(String(format: "NET ↓%.0fB/s ↑%.0fB/s  BAT=%@",
                 m.netDown, m.netUp, m.battery.map { "\($0)%" } ?? "n/a"))
    exit(0)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
