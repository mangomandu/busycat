import AppKit

// Hidden helper: `RuncatGPU --dump <dir>` writes each animation frame as a PNG
// (on white) so the cat artwork can be eyeballed without launching the menu bar.
if let idx = CommandLine.arguments.firstIndex(of: "--dump") {
    let dir = CommandLine.arguments.indices.contains(idx + 1)
        ? CommandLine.arguments[idx + 1] : "."
    FrameDumper.dump(to: dir, height: 64)
    exit(0)
}

// `RuncatGPU --metrics` prints one sample (after a 1s priming gap) and exits.
if CommandLine.arguments.contains("--metrics") {
    let s = SystemSampler()
    _ = s.sampleAll()
    Thread.sleep(forTimeInterval: 1.0)
    let m = s.sampleAll()
    print(String(format: "CPU=%.1f%%  GPU=%.1f%%  MEM=%.1f%%  DISK=%.1f%%",
                 m.cpu, m.gpu, m.memory, m.disk))
    print(String(format: "NET down=%.0f B/s  up=%.0f B/s", m.netDown, m.netUp))
    print("BATTERY=\(m.battery.map { "\($0)%" } ?? "n/a")  charging=\(m.charging)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
