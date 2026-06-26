import Foundation
import IOKit
import SystemConfiguration

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: CFTypeRef, _ matching: CFDictionary)
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: CFTypeRef, _ eventType: Int64,
                                         _ options: Int64, _ timestamp: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int64) -> Double

struct TemperatureSensor {
    var name: String
    var value: Double
    var source: String
}

/// One snapshot of everything RunCat-GPU monitors. Formulas mirror Activity
/// Monitor / RunCat (verified by reverse-engineering RunCat's detail menu).
struct Metrics {
    // CPU (normalized: fraction of total capacity, like AM's bottom load bar)
    var cpu: Double = 0          // % = system + user
    var cpuSystem: Double = 0    // %
    var cpuUser: Double = 0      // %
    // GPU
    var gpu: Double = 0          // % compute (compositing baseline removed) — drives the cat
    var gpuRaw: Double = 0       // % raw Device Utilization (incl. compositing)
    var gpuRender: Double = 0    // % Renderer (screen compositing / graphics)
    // Memory (Activity Monitor "Memory Used" = App + Wired + Compressed)
    var memory: Double = 0       // % used
    var memPressure: Double = 0  // % = (wired + compressed) / total
    var memApp: Double = 0       // bytes (internal/anonymous, purgeable included)
    var memWired: Double = 0     // bytes
    var memCompressed: Double = 0 // bytes
    // Disk (root volume, Finder convention: purgeable counts as free)
    var disk: Double = 0         // % used
    var diskUsed: Double = 0     // bytes
    var diskTotal: Double = 0    // bytes
    // Network
    var netDown: Double = 0      // bytes/s
    var netUp: Double = 0        // bytes/s
    var netType: String = "—"    // "Wi-Fi" / "이더넷" …
    var localIP: String = "—"
    // Battery (nil on desktop Macs)
    var battery: Double? = nil   // %
    var charging: Bool = false
    var onAC: Bool = false
    var batHealth: Double? = nil // % maximum capacity
    var batCycles: Int? = nil
    var batTemp: Double? = nil   // °C
    // Thermal (best effort; private-ish sensor names vary by Mac model)
    var thermalState: Int = ProcessInfo.ThermalState.nominal.rawValue
    var thermalTemp: Double? = nil // °C, hottest valid SMC/IOHID sensor
    var thermalTempSensor: String? = nil
    var thermalCPUTemp: Double? = nil // °C, IOHID pACC/eACC cluster max when available
    var thermalSensorCount: Int = 0
    var thermalTopSensors: [TemperatureSensor] = []
    var cpuSpeedLimit: Int? = nil  // %, from pmset -g therm
    var cpuSchedulerLimit: Int? = nil
    var cpuAvailableCPUs: Int? = nil
}

/// Samples all system metrics. Holds the small bit of state needed to turn the
/// kernel's monotonically-increasing counters (CPU ticks, interface bytes) into
/// per-interval rates.
final class SystemSampler {
    // CPU tick deltas
    // ~5-second exponential moving average for the fast/jittery rate metrics
    // (CPU, network), so the numbers read stable like Activity Monitor (which
    // averages over its ~5s update interval) and brief spikes — e.g. another app's
    // menu rendering — don't make the cat sprint.
    private let emaAlpha = 0.8  // exp(-1/5): ~5-second memory
    // Cache the host port once; mach_host_self() returns a send right the caller
    // must balance, so calling it every sample would slowly leak port references.
    private let host = mach_host_self()
    private var prevUser: UInt32 = 0
    private var prevSystem: UInt32 = 0
    private var prevIdle: UInt32 = 0
    private var prevNice: UInt32 = 0
    private var cpuPrimed = false
    private var sysEMA = 0.0
    private var userEMA = 0.0
    private var cpuEMAPrimed = false
    // Network byte deltas
    private var prevRx: UInt64 = 0
    private var prevTx: UInt64 = 0
    private var prevNetTime: Double = 0
    private var netPrimed = false
    private var downEMA = 0.0
    private var upEMA = 0.0
    private var netEMAPrimed = false
    // GPU EMA (raw + render smoothed independently; compute derived from them).
    private var gpuRawEMA = 0.0
    private var gpuRenderEMA = 0.0
    private var gpuEMAPrimed = false
    // Slow/heavy metrics (disk, network type+IP, battery, thermal) refreshed every ~5s
    // while the menu is open, not every tick — they barely change second-to-second.
    private var slowTick = 0
    private var slowPrimed = false
    private var cDisk: (percent: Double, used: Double, total: Double) = (0, 0, 0)
    private var cNet: (type: String, ip: String) = ("—", "—")
    private var cBat: (percent: Double?, charging: Bool, onAC: Bool,
                       health: Double?, cycles: Int?, temp: Double?) = (nil, false, false, nil, nil, nil)
    private var cThermal = ThermalReader.Snapshot()

    deinit { mach_port_deallocate(mach_task_self_, host) }

    /// Cheap metrics needed every second to drive the cat (CPU/GPU/memory are all
    /// single fast kernel calls). Used while the menu is closed — i.e. ~always.
    func sampleLight() -> Metrics {
        var m = Metrics()
        let c = cpu()
        m.cpu = c.total
        m.cpuSystem = c.system
        m.cpuUser = c.user
        let g = GPUReader.stats()
        if gpuEMAPrimed {
            gpuRawEMA = gpuRawEMA * emaAlpha + g.raw * (1 - emaAlpha)
            gpuRenderEMA = gpuRenderEMA * emaAlpha + g.render * (1 - emaAlpha)
        } else {
            gpuRawEMA = g.raw
            gpuRenderEMA = g.render
            gpuEMAPrimed = true
        }
        m.gpuRaw = gpuRawEMA
        m.gpuRender = gpuRenderEMA
        // Compute from the *smoothed* raw/render (not the pre-subtracted instant),
        // so ticks where integer render momentarily ≥ raw don't bias the cat low.
        m.gpu = MetricMath.gpuCompute(raw: gpuRawEMA, render: gpuRenderEMA)
        let mem = memory()
        m.memory = mem.percent
        m.memPressure = mem.pressure
        m.memApp = mem.app
        m.memWired = mem.wired
        m.memCompressed = mem.compressed
        return m
    }

    /// Full snapshot including the costlier reads (disk volume query, getifaddrs,
    /// IOKit). Only worth doing while the menu is actually open, since those extra
    /// rows aren't visible otherwise.
    func sampleAll() -> Metrics {
        var m = sampleLight()
        // Network throughput is meaningful per-second, so read it every tick…
        let net = network()
        m.netDown = net.down
        m.netUp = net.up
        // …but the heavy, slow-changing reads (disk volume query, SCNetworkInterface
        // lookup, full battery property dict) only every ~5s.
        if !slowPrimed || slowTick % 5 == 0 {
            cDisk = disk()
            cNet = networkInfo()
            cBat = battery()
            cThermal = ThermalReader.snapshot()
            slowPrimed = true
        }
        slowTick &+= 1
        m.disk = cDisk.percent
        m.diskUsed = cDisk.used
        m.diskTotal = cDisk.total
        m.netType = cNet.type
        m.localIP = cNet.ip
        m.battery = cBat.percent
        m.charging = cBat.charging
        m.onAC = cBat.onAC
        m.batHealth = cBat.health
        m.batCycles = cBat.cycles
        m.batTemp = cBat.temp
        m.thermalState = cThermal.state
        m.thermalTemp = cThermal.temperature
        m.thermalTempSensor = cThermal.temperatureSensor
        m.thermalCPUTemp = cThermal.cpuTemperature
        m.thermalSensorCount = cThermal.sensorCount
        m.thermalTopSensors = cThermal.topSensors
        m.cpuSpeedLimit = cThermal.cpuSpeedLimit
        m.cpuSchedulerLimit = cThermal.cpuSchedulerLimit
        m.cpuAvailableCPUs = cThermal.cpuAvailableCPUs
        return m
    }

    // MARK: CPU — busy% over the interval (HOST_CPU_LOAD_INFO tick delta)

    private func cpu() -> (total: Double, system: Double, user: Double) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                host_statistics(host, HOST_CPU_LOAD_INFO, reb, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }

        let user = info.cpu_ticks.0     // USER
        let system = info.cpu_ticks.1   // SYSTEM
        let idle = info.cpu_ticks.2     // IDLE
        let nice = info.cpu_ticks.3     // NICE
        // Normalized usage like Activity Monitor: user (incl. nice) and system as a
        // fraction of total, so system + user + idle == 100 exactly and the panel's
        // breakdown stays internally consistent. Each smoothed with its own EMA.
        defer {
            prevUser = user
            prevSystem = system
            prevIdle = idle
            prevNice = nice
            cpuPrimed = true
        }
        guard cpuPrimed else { return (0, 0, 0) }
        let dUser = Double(MetricMath.counterDelta(current: user, previous: prevUser)
            + MetricMath.counterDelta(current: nice, previous: prevNice))
        let dSys = Double(MetricMath.counterDelta(current: system, previous: prevSystem))
        let dIdle = Double(MetricMath.counterDelta(current: idle, previous: prevIdle))
        let dTotal = dUser + dSys + dIdle
        guard dTotal > 0 else { return (min(100, sysEMA + userEMA), sysEMA, userEMA) }
        let instSys = dSys / dTotal * 100
        let instUser = dUser / dTotal * 100
        if cpuEMAPrimed {
            sysEMA = sysEMA * emaAlpha + instSys * (1 - emaAlpha)
            userEMA = userEMA * emaAlpha + instUser * (1 - emaAlpha)
        } else {
            sysEMA = instSys
            userEMA = instUser
            cpuEMAPrimed = true
        }
        return (min(100, sysEMA + userEMA), sysEMA, userEMA)
    }

    // MARK: Memory — Activity Monitor-like model: Used = App + Wired + Compressed.
    // App Memory uses internal/anonymous pages, including purgeable pages.

    private func memory() -> (percent: Double, pressure: Double, app: Double, wired: Double, compressed: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                host_statistics64(host, HOST_VM_INFO64, reb, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0, 0, 0, 0) }
        let pageSize = Double(vm_kernel_page_size)
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        // App Memory = anonymous pages (internal_page_count), matching Activity
        // Monitor's "App Memory" (purgeable included).
        let app = Double(stats.internal_page_count) * pageSize
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        guard total > 0 else { return (0, 0, 0, 0, 0) }
        let used = app + wired + compressed
        let pct = min(100, used / Double(total) * 100)
        let pressure = min(100, (wired + compressed) / Double(total) * 100)
        return (pct, pressure, app, wired, compressed)
    }

    // MARK: Disk — root volume; available counts purgeable as free (Finder/RunCat).

    private func disk() -> (percent: Double, used: Double, total: Double) {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                      .volumeAvailableCapacityForImportantUsageKey]),
            let total = v.volumeTotalCapacity, total > 0
        else { return (0, 0, 0) }
        return MetricMath.diskUsage(
            total: Int64(total),
            importantAvailable: v.volumeAvailableCapacityForImportantUsage,
            regularAvailable: v.volumeAvailableCapacity.map(Int64.init))
    }

    // MARK: Network — bytes/s up & down across physical interfaces

    private func network() -> (down: Double, up: Double) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                p.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK)
            else { continue }
            let name = String(cString: p.pointee.ifa_name)
            if name.hasPrefix("lo") || name.hasPrefix("utun") || name.hasPrefix("gif")
                || name.hasPrefix("stf") { continue }
            if let data = p.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx &+= UInt64(data.pointee.ifi_ibytes)
                tx &+= UInt64(data.pointee.ifi_obytes)
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        defer { prevRx = rx; prevTx = tx; prevNetTime = now; netPrimed = true }
        guard netPrimed else { return (0, 0) }
        let dt = now - prevNetTime
        guard dt > 0 else { return (0, 0) }
        // ifi_*bytes are 32-bit and can wrap; clamp negative deltas to 0.
        let down = rx >= prevRx ? Double(rx - prevRx) / dt : 0
        let up = tx >= prevTx ? Double(tx - prevTx) / dt : 0
        if netEMAPrimed {
            downEMA = downEMA * emaAlpha + down * (1 - emaAlpha)
            upEMA = upEMA * emaAlpha + up * (1 - emaAlpha)
        } else {
            downEMA = down
            upEMA = up
            netEMAPrimed = true
        }
        return (downEMA, upEMA)
    }

    // MARK: Battery — AppleSmartBattery (raw mAh → decimal %, health, cycles, temp)

    private func battery() -> (percent: Double?, charging: Bool, onAC: Bool,
                               health: Double?, cycles: Int?, temp: Double?) {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return (nil, false, false, nil, nil, nil) }
        defer { IOObjectRelease(svc) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let d = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return (nil, false, false, nil, nil, nil) }

        // Displayed charge % = the calibrated CurrentCapacity/MaxCapacity that the
        // menu bar / System Settings / pmset show (NOT the raw mAh ratio).
        let curCap = d["CurrentCapacity"] as? Int
        let maxCap = d["MaxCapacity"] as? Int
        let rawMax = d["AppleRawMaxCapacity"] as? Int
        let design = d["DesignCapacity"] as? Int
        let onAC = (d["ExternalConnected"] as? Bool) ?? false
        let charging = (d["IsCharging"] as? Bool) ?? false
        let cycles = d["CycleCount"] as? Int
        // Temperature is centi-°C on this hardware (3030 → 30.3°C). Some models
        // report differently; show only a plausible value, else "—".
        let temp = (d["Temperature"] as? Int).map { Double($0) / 100 }.flatMap { (0...80).contains($0) ? $0 : nil }

        var pct: Double? = nil
        if let c = curCap, let m = maxCap, m > 0 { pct = Double(c) / Double(m) * 100 }
        // Battery health (= System Settings "Maximum Capacity"): raw max vs design.
        var health: Double? = nil
        if let m = rawMax, let dz = design, dz > 0 { health = min(100, Double(m) / Double(dz) * 100) }
        return (pct, charging, onAC, health, cycles, temp)
    }

    // MARK: Network type + local IPv4 of the primary interface

    private func networkInfo() -> (type: String, ip: String) {
        var bsd: String?
        if let store = SCDynamicStoreCreate(nil, "BusyCat" as CFString, nil, nil),
            let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any] {
            bsd = dict["PrimaryInterface"] as? String
        }
        let ip = ipv4(for: bsd)
        let type = bsd.flatMap(interfaceDisplayName) ?? "—"
        return (type, ip)
    }

    private func ipv4(for iface: String?) -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "—" }
        defer { freeifaddrs(ifaddr) }
        var fallback = "—"
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if let want = iface, name == want { return ip }
            if fallback == "—" { fallback = ip }
        }
        return fallback
    }

    private func interfaceDisplayName(_ bsd: String) -> String? {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        for i in all where (SCNetworkInterfaceGetBSDName(i) as String?) == bsd {
            return SCNetworkInterfaceGetLocalizedDisplayName(i) as String?
        }
        return nil
    }
}

enum ThermalReader {
    struct Snapshot {
        var state: Int = ProcessInfo.ThermalState.nominal.rawValue
        var temperature: Double? = nil
        var temperatureSensor: String? = nil
        var cpuTemperature: Double? = nil
        var sensorCount: Int = 0
        var topSensors: [TemperatureSensor] = []
        var cpuSpeedLimit: Int? = nil
        var cpuSchedulerLimit: Int? = nil
        var cpuAvailableCPUs: Int? = nil
    }

    private static let client: CFTypeRef? = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?
        .takeRetainedValue()

    static func snapshot() -> Snapshot {
        var s = Snapshot(state: ProcessInfo.processInfo.thermalState.rawValue)
        let hid = temperatureSensors()
        let smc = SMCReader.shared.temperatureSensors()
        let sensors = (hid + smc).filter { $0.value > 0 && $0.value < 120 }
        s.sensorCount = sensors.count
        s.topSensors = sensors.sorted { $0.value > $1.value }.prefix(12).map { $0 }
        if let hottest = s.topSensors.first {
            s.temperature = hottest.value
            s.temperatureSensor = "\(hottest.name) · \(hottest.source)"
        }
        let cpu = hid.filter { $0.name.hasPrefix("pACC") || $0.name.hasPrefix("eACC") }
        s.cpuTemperature = cpu.map(\.value).max()

        let limits = parsePMSetTherm(runPMSetTherm())
        s.cpuSpeedLimit = limits.speed
        s.cpuSchedulerLimit = limits.scheduler
        s.cpuAvailableCPUs = limits.available
        return s
    }

    static func parsePMSetTherm(_ output: String)
        -> (speed: Int?, scheduler: Int?, available: Int?) {
        var speed: Int?
        var scheduler: Int?
        var available: Int?
        for line in output.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            switch parts[0] {
            case "CPU_Speed_Limit": speed = value
            case "CPU_Scheduler_Limit": scheduler = value
            case "CPU_Available_CPUs": available = value
            default: continue
            }
        }
        return (speed, scheduler, available)
    }

    private static func runPMSetTherm() -> String {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "therm"]
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return ""
        }
        guard task.terminationStatus == 0 else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func temperatureSensors() -> [TemperatureSensor] {
        guard let client else { return [] }
        let matching: CFDictionary = [
            "PrimaryUsagePage" as CFString: 0xFF00 as CFNumber,
            "PrimaryUsage" as CFString: 0x05 as CFNumber,
        ] as CFDictionary
        IOHIDEventSystemClientSetMatching(client, matching)
        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }

        var values: [String: Double] = [:]
        for service in services {
            guard let event = IOHIDServiceClientCopyEvent(service, 0x0F, 0, 0)?.takeRetainedValue()
            else { continue }
            let temp = IOHIDEventGetFloatValue(event, 0x0F << 16)
            guard temp > 0, temp < 120 else { continue }
            let name = sensorName(for: service) ?? "Unknown"
            values[name] = temp
        }
        return values.map { TemperatureSensor(name: $0.key, value: $0.value, source: "IOHID") }
    }

    private static func sensorName(for service: CFTypeRef) -> String? {
        if let product = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?
            .takeRetainedValue() as? String {
            return product
        }
        if let location = IOHIDServiceClientCopyProperty(service, "LocationID" as CFString)?
            .takeRetainedValue() as? NSNumber {
            return String(format: "Unknown-FF00-05-%llX", location.uint64Value)
        }
        return nil
    }
}

private final class SMCReader {
    static let shared = SMCReader()

    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var padding0: UInt8 = 0
        var padding1: UInt8 = 0
        var padding2: UInt8 = 0
    }

    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private let kSMCUserClientOpen: UInt32 = 0
    private let kSMCUserClientClose: UInt32 = 1
    private let kSMCHandleYPCEvent: UInt32 = 2
    private let kSMCReadKey: UInt8 = 5
    private let kSMCGetKeyFromIndex: UInt8 = 8
    private let kSMCGetKeyInfo: UInt8 = 9
    private let kSMCSuccess: UInt8 = 0
    private let keyCountKey = SMCReader.fourCC("#KEY")

    private var connection: io_connect_t = 0
    private var keys: [UInt32] = []
    private var keyInfoCache: [UInt32: SMCKeyInfoData] = [:]

    private init() {
        open()
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func temperatureSensors() -> [TemperatureSensor] {
        guard connection != 0 else { return [] }
        if keys.isEmpty { keys = readKeys() }
        return keys.compactMap { key -> TemperatureSensor? in
            guard key >> 24 == 84, let sample = readKey(key),
                  let value = decodeTemperature(sample.data, type: sample.type),
                  value > 0, value < 120
            else { return nil }
            return TemperatureSensor(name: SMCReader.fourCCString(key), value: value, source: "SMC")
        }
    }

    private func open() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return }
        connection = conn
    }

    private func readKeys() -> [UInt32] {
        let count = readKeyCount()
        guard count > 0 else { return [] }
        var out: [UInt32] = []
        for i in 0..<count {
            if let key = readKey(at: i), key != 0 { out.append(key) }
        }
        return out
    }

    private func readKeyCount() -> UInt32 {
        guard let sample = readKey(keyCountKey), sample.data.count <= 4 else { return 0 }
        var n: UInt32 = 0
        for (i, b) in sample.data.enumerated() {
            n |= UInt32(b) << UInt32(i * 8)
        }
        return n
    }

    private func readKey(at index: UInt32) -> UInt32? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.data8 = kSMCGetKeyFromIndex
        input.data32 = index
        guard call(function: kSMCHandleYPCEvent, input: &input, output: &output),
              output.result == kSMCSuccess else { return nil }
        return output.key
    }

    private func readKey(_ key: UInt32) -> (data: [UInt8], type: UInt32)? {
        guard let info = keyInfo(for: key) else { return nil }
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = key
        input.data8 = kSMCReadKey
        input.keyInfo.dataSize = info.dataSize
        guard call(function: kSMCHandleYPCEvent, input: &input, output: &output),
              output.result == kSMCSuccess else { return nil }
        let size = min(Int(info.dataSize), 32)
        let raw = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return (Array(raw.reversed()), info.dataType)
    }

    private func keyInfo(for key: UInt32) -> SMCKeyInfoData? {
        if let cached = keyInfoCache[key] { return cached }
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = key
        input.data8 = kSMCGetKeyInfo
        guard call(function: kSMCHandleYPCEvent, input: &input, output: &output),
              output.result == kSMCSuccess else { return nil }
        keyInfoCache[key] = output.keyInfo
        return output.keyInfo
    }

    private func call(function: UInt32, input: inout SMCParamStruct, output: inout SMCParamStruct) -> Bool {
        guard connection != 0 else { return false }
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        guard IOConnectCallMethod(connection, kSMCUserClientOpen, nil, 0, nil, 0,
                                  nil, nil, nil, nil) == kIOReturnSuccess
        else { return false }
        let result = IOConnectCallStructMethod(connection, function, &input, inputSize, &output, &outputSize)
        IOConnectCallMethod(connection, kSMCUserClientClose, nil, 0, nil, 0, nil, nil, nil, nil)
        return result == kIOReturnSuccess
    }

    private func decodeTemperature(_ data: [UInt8], type: UInt32) -> Double? {
        let typeName = SMCReader.fourCCString(type)
        switch typeName {
        case "sp78":
            guard data.count == 2 else { return nil }
            return Double(data[1] & 0x7F) + Double(data[0]) / 256.0
        case "flt ":
            guard data.count == 4 else { return nil }
            let bits = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Double(Float32(bitPattern: bits))
        default:
            return nil
        }
    }

    private static func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func fourCCString(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

/// Reads GPU utilization from the IOKit registry (no sudo needed on Apple
/// Silicon). The supported path has one AGX accelerator and exposes Device and
/// Renderer utilization counters.
///
/// Metric choice matters — and is easy to get backwards:
///   - "Device Utilization %" = overall GPU busy, **including Metal compute (MPS)**.
///     This is what ML / embedding workloads drive. Cross-checked against macOS
///     Activity Monitor: an MPS embedding job showed 93% GPU there and "Device
///     Utilization %" ≈ 100 here, in agreement.
///   - "Renderer Utilization %" / "Tiler Utilization %" cover only the **graphics**
///     pipeline (raster / geometry). During pure compute they read near 0 — so
///     relying on them makes the cat look idle during exactly the GPU work we care
///     about. (That mistake is why this once read low during embeddings.)
/// Older / third-party counters are retained as best-effort display fallbacks,
/// but compute isolation is only guaranteed on the Apple Silicon Device path.
enum GPUReader {
    // The accelerator service is matched once and cached: re-matching every second
    // is wasteful. We also read only the "PerformanceStatistics" property instead
    // of copying the accelerator's entire (large) property set each tick.
    private static var cachedService: io_object_t = 0

    /// Returns the GPU breakdown in one registry read:
    ///   - raw:     "Device Utilization %" (total busy, incl. compositing) — matches AM
    ///   - render:  "Renderer Utilization %" (screen compositing / graphics)
    ///
    /// Key observation: screen compositing drives Device and Renderer together
    /// (Device ≈ Renderer), while Metal compute (embeddings) drives Device far
    /// above Renderer. So `Device − Renderer` isolates real compute — a brief
    /// menu/Mission-Control composite ≈ 0, an embedding stays high — far better
    /// than a fixed baseline that big menu renders could exceed.
    static func stats() -> (raw: Double, render: Double) {
        if cachedService == 0 { cachedService = findAccelerator() }
        guard cachedService != 0 else { return (0, 0) }
        guard let perf = perfStats(cachedService) else {
            IOObjectRelease(cachedService)  // service vanished — re-match next time
            cachedService = 0
            return (0, 0)
        }
        return counters(from: perf)
    }

    /// First IOAccelerator that exposes PerformanceStatistics (one AGX GPU on
    /// Apple Silicon). Returned object is retained; the caller keeps it cached.
    private static func findAccelerator() -> io_object_t {
        guard let matching = IOServiceMatching("IOAccelerator") else { return 0 }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }

        var chosen: io_object_t = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if chosen == 0, perfStats(service) != nil {
                chosen = service  // keep this one retained
            } else {
                IOObjectRelease(service)
            }
            service = IOIteratorNext(iterator)
        }
        return chosen
    }

    private static func perfStats(_ service: io_object_t) -> [String: Any]? {
        guard let cf = IORegistryEntryCreateCFProperty(
            service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return cf.takeRetainedValue() as? [String: Any]
    }

    static func counters(from perf: [String: Any])
        -> (raw: Double, render: Double) {
        func percent(_ key: String) -> Double? {
            guard let value = perf[key] as? NSNumber else { return nil }
            return max(0, min(100, value.doubleValue))
        }

        let render = percent("Renderer Utilization %") ?? 0
        // "Device Utilization %" is the right signal: 0 at idle, ~100 under Metal
        // compute (embeddings). Do NOT fold in "Renderer"/"Tiler" — those read
        // ~10-15% just from normal menu-bar compositing (including our own cat),
        // which would keep the cat sprinting at idle and waste CPU.
        if let raw = percent("Device Utilization %") {
            return (raw, render)
        }

        // Best-effort display fallback only. These GPUs do not expose enough
        // information to guarantee Device−Renderer compute isolation.
        if let activity = percent("GPU Activity(%)") {
            return (activity, render)
        }
        let pipeline = max(render, percent("Tiler Utilization %") ?? 0)
        return (pipeline, render)
    }
}
