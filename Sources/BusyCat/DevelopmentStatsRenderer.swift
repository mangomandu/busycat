#if BUSYCAT_DEVELOPMENT_TOOLS
import Cocoa

/// Renders the menu panel for README screenshots. This file is compiled only in
/// debug builds and is deliberately absent from the distributed app binary.
func renderDevelopmentStatsPanel(to outputURL: URL) -> Bool {
    _ = NSApplication.shared
    var metrics = Metrics()
    metrics.cpu = 5.6
    metrics.cpuSystem = 2.9
    metrics.cpuUser = 2.7
    metrics.gpuCompute = 0
    metrics.gpuRaw = 0
    metrics.gpuRender = 0
    metrics.gpuAvailable = true
    metrics.memory = 40.5
    metrics.memoryPressure = .normal
    metrics.memApp = 17.7e9
    metrics.memWired = 2.8e9
    metrics.memCompressed = 323.7e6
    metrics.disk = 10.4
    metrics.diskUsed = 103.6e9
    metrics.diskTotal = 994.6e9
    metrics.diskAvailable = true
    metrics.netRateAvailable = true
    metrics.battery = 99
    metrics.onAC = false
    metrics.charging = false
    metrics.batHealth = 100
    metrics.batCycles = 3
    metrics.batTemp = 30.1
    metrics.thermalState = ProcessInfo.ThermalState.nominal.rawValue
    metrics.thermalTemp = 61.0
    metrics.thermalTempSensor = "TCMb · SMC"
    metrics.thermalCPUTemp = 51.8
    metrics.cpuSpeedLimit = 100
    metrics.cpuSchedulerLimit = 100
    metrics.cpuAvailableCPUs = 10
    metrics.thermalSensorCount = 58
    metrics.thermalTopSensors = [
        TemperatureSensor(name: "TCMb", value: 61.0, source: "SMC"),
        TemperatureSensor(name: "pACC", value: 51.8, source: "IOHID"),
        TemperatureSensor(name: "PMU tcal", value: 51.0, source: "IOHID"),
        TemperatureSensor(name: "gas gauge battery", value: 30.1, source: "IOHID"),
    ]
    metrics.netType = "Wi-Fi"
    metrics.localIP = "192.168.0.2"
    metrics.netUp = 819
    metrics.netDown = 409

    let view = StatsView()
    view.update(metrics, history: (0..<60).map { 20 + 18 * sin(Double($0) / 4) },
                meterColor: .systemGray)
    guard let dark = NSAppearance(named: .darkAqua) else { return false }
    view.appearance = dark
    let size = view.frame.size
    let image = NSImage(size: size, flipped: true) { rect in
        dark.performAsCurrentDrawingAppearance {
            NSColor(white: 0.15, alpha: 1).setFill()
            rect.fill()
            view.draw(rect)
        }
        return true
    }

    let scale: CGFloat = 2
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0)
    representation?.size = size
    if let representation, let context = NSGraphicsContext(bitmapImageRep: representation) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    guard let representation,
          let png = representation.representation(using: .png, properties: [:])
    else { return false }
    do {
        try png.write(to: outputURL, options: .atomic)
        print("wrote \(outputURL.path) \(representation.pixelsWide)x\(representation.pixelsHigh)")
        return true
    } catch {
        fputs("Could not write \(outputURL.path): \(error)\n", stderr)
        return false
    }
}
#endif
