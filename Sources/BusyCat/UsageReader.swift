import Foundation
import Darwin
import IOKit
import SystemConfiguration

/// Temperature access uses private IOHID symbols whose availability isn't
/// guaranteed by the SDK. Resolve them at runtime so a future macOS can disable
/// temperature details without preventing the whole app from launching.
private enum HIDPrivateAPI {
    typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Void
    typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int64, Int64) -> Unmanaged<CFTypeRef>?
    typealias GetFloatValue = @convention(c) (CFTypeRef, Int64) -> Double

    private final class Loader: @unchecked Sendable {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    }

    private static let loader = Loader()

    static let create: Create? = load("IOHIDEventSystemClientCreate", as: Create.self)
    static let setMatching: SetMatching? = load("IOHIDEventSystemClientSetMatching", as: SetMatching.self)
    static let copyServices: CopyServices? = load("IOHIDEventSystemClientCopyServices", as: CopyServices.self)
    static let copyProperty: CopyProperty? = load("IOHIDServiceClientCopyProperty", as: CopyProperty.self)
    static let copyEvent: CopyEvent? = load("IOHIDServiceClientCopyEvent", as: CopyEvent.self)
    static let getFloatValue: GetFloatValue? = load("IOHIDEventGetFloatValue", as: GetFloatValue.self)

    private static func load<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = loader.handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}

struct TemperatureSensor: Sendable {
    var name: String
    var value: Double
    var source: String
}

/// One snapshot of everything RunCat-GPU monitors. Formulas mirror Activity
/// Monitor / RunCat (verified by reverse-engineering RunCat's detail menu).
struct Metrics: Sendable {
    // CPU (normalized: fraction of total capacity, like AM's bottom load bar)
    var cpu: Double = 0          // % = system + user
    var cpuSystem: Double = 0    // %
    var cpuUser: Double = 0      // %
    // GPU
    var gpuCompute: Double = 0   // % compute estimate (renderer removed) — drives the cat
    var gpuRaw: Double = 0       // % raw Device Utilization (incl. graphics/display rendering)
    var gpuRender: Double = 0    // % Renderer (graphics / display rendering)
    var gpuAvailable: Bool = false
    // Memory (Activity Monitor "Memory Used" = App + Wired + Compressed)
    var memory: Double = 0       // % used
    var memoryPressure: MemoryPressureLevel = .normal
    var memApp: Double = 0       // bytes (internal/anonymous, purgeable included)
    var memWired: Double = 0     // bytes
    var memCompressed: Double = 0 // bytes
    // Disk (root volume, Finder convention: purgeable counts as free)
    var disk: Double = 0         // % used
    var diskUsed: Double = 0     // bytes
    var diskTotal: Double = 0    // bytes
    var diskAvailable: Bool = false
    // Network
    var netDown: Double = 0      // bytes/s
    var netUp: Double = 0        // bytes/s
    var netRateAvailable: Bool = false
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
final class SystemSampler: @unchecked Sendable {
    // CPU tick deltas
    // ~5-second exponential moving average for the fast/jittery rate metrics
    // (CPU, network), so the numbers read stable like Activity Monitor (which
    // averages over its ~5s update interval) and brief spikes — e.g. another app's
    // menu rendering — don't make the cat sprint.
    private let emaAlpha = 0.8  // exp(-1/5): ~5-second memory
    // Cache the host port once; mach_host_self() returns a send right the caller
    // must balance, so calling it every sample would slowly leak port references.
    private let host = mach_host_self()
    private let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
    private let pageSize = Double(getpagesize())
    private let memoryPressureMonitor = MemoryPressureMonitor()
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
    private var prevNetInterface = ""
    private var netPrimed = false
    private var downEMA = 0.0
    private var upEMA = 0.0
    private var netEMAPrimed = false
    // GPU EMA (raw + render smoothed independently; compute derived from them).
    private var gpuRawEMA = 0.0
    private var gpuRenderEMA = 0.0
    private var gpuSubtractRenderer = true
    private var gpuEMAPrimed = false
    // Slow/heavy metrics (disk, network type+IP, battery, thermal) refreshed by
    // wall time during prewarm/menu-open sampling; they barely change each second.
    private let slowRefreshInterval = 5.0
    private var nextSlowRefresh = 0.0
    private var slowPrimed = false
    private var cDisk: (percent: Double, used: Double, total: Double, available: Bool) = (0, 0, 0, false)
    private var cNet: (type: String, ip: String, bsd: String?) = ("—", "—", nil)
    private var cBat: (percent: Double?, charging: Bool, onAC: Bool,
                       health: Double?, cycles: Int?, temp: Double?) = (nil, false, false, nil, nil, nil)
    private var cThermal = ThermalReader.Snapshot()
    private var cStatusTemperature: Double?
    private var nextStatusTemperatureRefresh = 0.0
    private var statusTemperaturePrimed = false

    deinit { mach_port_deallocate(mach_task_self_, host) }

    private func resetCPUHistory() {
        cpuPrimed = false
        cpuEMAPrimed = false
        sysEMA = 0
        userEMA = 0
    }

    private func resetGPUHistory() {
        gpuEMAPrimed = false
        gpuRawEMA = 0
        gpuRenderEMA = 0
    }

    func resetFastHistory() {
        resetCPUHistory()
        resetGPUHistory()
        netPrimed = false
        netEMAPrimed = false
    }

    /// Cheap metrics needed every second to drive the cat (CPU/GPU/memory are all
    /// single fast kernel calls). Used while the menu is closed — i.e. ~always.
    func sampleLight(fields: SampleFields = .all) -> Metrics {
        var m = Metrics()
        if fields.contains(.cpu) {
            let c = cpu()
            m.cpu = c.total
            m.cpuSystem = c.system
            m.cpuUser = c.user
        } else {
            resetCPUHistory()
        }
        if fields.contains(.gpu) {
            updateGPU(GPUReader.stats(), into: &m)
        } else {
            resetGPUHistory()
        }
        if fields.contains(.memory) {
            let mem = memory()
            m.memory = mem.percent
            m.memoryPressure = memoryPressureMonitor.level
            m.memApp = mem.app
            m.memWired = mem.wired
            m.memCompressed = mem.compressed
        }
        m.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        return m
    }

    func updateGPU(
        _ g: (raw: Double, render: Double, subtractRenderer: Bool, available: Bool),
        into m: inout Metrics
    ) {
        if g.available {
            if gpuEMAPrimed {
                gpuRawEMA = gpuRawEMA * emaAlpha + g.raw * (1 - emaAlpha)
                gpuRenderEMA = gpuRenderEMA * emaAlpha + g.render * (1 - emaAlpha)
            } else {
                gpuRawEMA = g.raw
                gpuRenderEMA = g.render
                gpuEMAPrimed = true
            }
        } else {
            resetGPUHistory()
        }
        gpuSubtractRenderer = g.subtractRenderer
        m.gpuAvailable = g.available
        m.gpuRaw = gpuRawEMA
        m.gpuRender = gpuRenderEMA
        // Compute from the *smoothed* raw/render (not the pre-subtracted instant),
        // so ticks where integer render momentarily ≥ raw don't bias the cat low.
        m.gpuCompute = gpuSubtractRenderer
            ? MetricMath.gpuCompute(raw: gpuRawEMA, render: gpuRenderEMA)
            : gpuRawEMA
    }

    /// Lightweight temperature for menu-bar text. This reads only temperature
    /// sensors and avoids the full menu snapshot path (disk/network/battery/pmset).
    func temperatureForStatusText() -> Double? {
        let now = ProcessInfo.processInfo.systemUptime
        if !statusTemperaturePrimed || now >= nextStatusTemperatureRefresh {
            cStatusTemperature = ThermalReader.hottestTemperature()
            statusTemperaturePrimed = true
            nextStatusTemperatureRefresh = now + slowRefreshInterval
        }
        return cStatusTemperature
    }

    /// Full snapshot including the costlier reads (disk volume query, getifaddrs,
    /// IOKit). Called once for background prewarm, then while the detailed menu is
    /// open so its extra rows stay current.
    func sampleAll() -> Metrics {
        var m = sampleLight(fields: .all)
        // Heavy, slow-changing reads (disk volume query, SCNetworkInterface
        // lookup, full battery property dict) only every ~5s.
        let now = ProcessInfo.processInfo.systemUptime
        if !slowPrimed || now >= nextSlowRefresh {
            cDisk = disk()
            cNet = networkInfo()
            cBat = battery()
            cThermal = ThermalReader.snapshot()
            cStatusTemperature = cThermal.temperature
            statusTemperaturePrimed = true
            nextStatusTemperatureRefresh = now + slowRefreshInterval
            slowPrimed = true
            nextSlowRefresh = now + slowRefreshInterval
        }
        // Network throughput is meaningful per-second. Use the primary interface
        // selected above so the displayed interface/IP and rate describe the same
        // connection rather than summing unrelated AirDrop/bridge traffic.
        let net = network(interface: cNet.bsd)
        m.netDown = net.down
        m.netUp = net.up
        m.netRateAvailable = net.available
        m.disk = cDisk.percent
        m.diskUsed = cDisk.used
        m.diskTotal = cDisk.total
        m.diskAvailable = cDisk.available
        m.netType = cNet.type
        m.localIP = cNet.ip
        m.battery = cBat.percent
        m.charging = cBat.charging
        m.onAC = cBat.onAC
        m.batHealth = cBat.health
        m.batCycles = cBat.cycles
        m.batTemp = cBat.temp
        m.thermalState = ProcessInfo.processInfo.thermalState.rawValue
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
        guard result == KERN_SUCCESS else {
            resetCPUHistory()
            return (0, 0, 0)
        }
        return updateCPU(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                         idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    func updateCPU(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)
        -> (total: Double, system: Double, user: Double) {
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

    private func memory() -> (percent: Double, app: Double, wired: Double, compressed: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                host_statistics64(host, HOST_VM_INFO64, reb, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0, 0, 0) }
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        // App Memory = anonymous pages (internal_page_count), matching Activity
        // Monitor's "App Memory" (purgeable included).
        let app = Double(stats.internal_page_count) * pageSize
        guard totalMemory > 0 else { return (0, 0, 0, 0) }
        let used = app + wired + compressed
        let pct = min(100, used / totalMemory * 100)
        return (pct, app, wired, compressed)
    }

    // MARK: Disk — root volume; available counts purgeable as free (Finder/RunCat).

    private func disk() -> (percent: Double, used: Double, total: Double, available: Bool) {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                      .volumeAvailableCapacityForImportantUsageKey]),
            let total = v.volumeTotalCapacity, total > 0
        else { return (0, 0, 0, false) }
        guard let usage = MetricMath.diskUsage(
            total: Int64(total),
            importantAvailable: v.volumeAvailableCapacityForImportantUsage,
            regularAvailable: v.volumeAvailableCapacity.map(Int64.init))
        else { return (0, 0, Double(total), false) }
        return (usage.percent, usage.used, usage.total, true)
    }

    // MARK: Network — bytes/s up & down across physical interfaces

    private func network(interface: String?) -> (down: Double, up: Double, available: Bool) {
        guard let interface else { return (0, 0, false) }
        guard let counters = networkCounters64(interface: interface) else { return (0, 0, false) }
        let rx = counters.rx
        let tx = counters.tx
        let identity = interface

        let now = ProcessInfo.processInfo.systemUptime
        defer {
            prevRx = rx
            prevTx = tx
            prevNetTime = now
            prevNetInterface = identity
            netPrimed = true
        }
        guard netPrimed, prevNetInterface == identity else {
            netEMAPrimed = false
            return (0, 0, false)
        }
        let dt = now - prevNetTime
        // A long gap means the menu was closed or the Mac slept. Re-prime instead
        // of showing a long-term average as though it were the current rate.
        guard dt > 0, dt <= 3, rx >= prevRx, tx >= prevTx else {
            netEMAPrimed = false
            return (0, 0, false)
        }
        let down = Double(rx - prevRx) / dt
        let up = Double(tx - prevTx) / dt
        if netEMAPrimed {
            downEMA = downEMA * emaAlpha + down * (1 - emaAlpha)
            upEMA = upEMA * emaAlpha + up * (1 - emaAlpha)
        } else {
            downEMA = down
            upEMA = up
            netEMAPrimed = true
        }
        return (downEMA, upEMA, true)
    }

    /// `getifaddrs().ifa_data` exposes 32-bit byte counters that wrap after 4 GiB.
    /// NET_RT_IFLIST2 provides `if_data64`, which remains stable during sustained
    /// high-speed transfers.
    private func networkCounters64(interface wanted: String) -> (rx: UInt64, tx: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: length)
        let readResult = bytes.withUnsafeMutableBytes { raw in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &length, nil, 0)
        }
        guard readResult == 0 else { return nil }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var matched = false
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                var header = if_msghdr()
                memcpy(&header, base.advanced(by: offset), MemoryLayout<if_msghdr>.size)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }

                if header.ifm_type == RTM_IFINFO2,
                   messageLength >= MemoryLayout<if_msghdr2>.size {
                    var message = if_msghdr2()
                    memcpy(&message, base.advanced(by: offset), MemoryLayout<if_msghdr2>.size)
                    let flags = Int32(message.ifm_flags)
                    let name = interfaceName(index: UInt32(message.ifm_index))
                    if (flags & IFF_UP) != 0, let name, shouldCountInterface(name, wanted: wanted) {
                        matched = true
                        rx &+= message.ifm_data.ifi_ibytes
                        tx &+= message.ifm_data.ifi_obytes
                    }
                }
                offset += messageLength
            }
        }
        return matched ? (rx, tx) : nil
    }

    private func interfaceName(index: UInt32) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        return name.withUnsafeMutableBufferPointer { buffer in
            guard if_indextoname(index, buffer.baseAddress) != nil else { return nil }
            return String(cString: buffer.baseAddress!)
        }
    }

    private func shouldCountInterface(_ name: String, wanted: String) -> Bool {
        name == wanted
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
        let cycles = (d["CycleCount"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
        // Temperature is centi-°C on this hardware (3030 → 30.3°C). Some models
        // report differently; show only a plausible value, else "—".
        let temp = (d["Temperature"] as? Int).map { Double($0) / 100 }.flatMap { (0...80).contains($0) ? $0 : nil }

        var pct: Double? = nil
        if let c = curCap, let m = maxCap, m > 0 {
            pct = max(0, min(100, Double(c) / Double(m) * 100))
        }
        // Battery health (= System Settings "Maximum Capacity"): raw max vs design.
        var health: Double? = nil
        if let m = rawMax, let dz = design, dz > 0 {
            health = max(0, min(100, Double(m) / Double(dz) * 100))
        }
        return (pct, charging, onAC, health, cycles, temp)
    }

    // MARK: Network type + local address of the primary interface

    private func networkInfo() -> (type: String, ip: String, bsd: String?) {
        var bsd: String?
        if let store = SCDynamicStoreCreate(nil, "BusyCat" as CFString, nil, nil) {
            for family in ["IPv4", "IPv6"] {
                let key = "State:/Network/Global/\(family)" as CFString
                if let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any],
                   let primary = dict["PrimaryInterface"] as? String {
                    bsd = primary
                    break
                }
            }
        }
        let ip = localAddress(for: bsd)
        let type = bsd.map { interfaceDisplayName($0) ?? fallbackInterfaceDisplayName($0) } ?? "—"
        return (type, ip, bsd)
    }

    private func localAddress(for iface: String?) -> String {
        guard let iface else { return "—" }
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "—" }
        defer { freeifaddrs(ifaddr) }
        var globalIPv6: String?
        var linkLocalIPv6: String?
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
                    || addr.pointee.sa_family == UInt8(AF_INET6),
                  (p.pointee.ifa_flags & UInt32(IFF_UP)) != 0
            else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name == iface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty else { continue }
            if addr.pointee.sa_family == UInt8(AF_INET) { return ip }
            if ip.lowercased().hasPrefix("fe80:") {
                if linkLocalIPv6 == nil { linkLocalIPv6 = ip }
            } else if ip != "::1" {
                if globalIPv6 == nil { globalIPv6 = ip }
            }
        }
        return globalIPv6 ?? linkLocalIPv6 ?? "—"
    }

    private func interfaceDisplayName(_ bsd: String) -> String? {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        for i in all where (SCNetworkInterfaceGetBSDName(i) as String?) == bsd {
            let kind = SCNetworkInterfaceGetInterfaceType(i) as String?
            if kind == (kSCNetworkInterfaceTypeIEEE80211 as String) { return "Wi-Fi" }
            if kind == (kSCNetworkInterfaceTypeEthernet as String) { return "Ethernet" }
            return SCNetworkInterfaceGetLocalizedDisplayName(i) as String?
        }
        return nil
    }

    private func fallbackInterfaceDisplayName(_ bsd: String) -> String {
        bsd.hasPrefix("utun") ? "VPN" : bsd
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

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let client: CFTypeRef? = HIDPrivateAPI.create?(kCFAllocatorDefault)?.takeRetainedValue()
        var cachedPMSetTherm = ""
        var nextPMSetRefresh = 0.0
    }

    private static let sharedState = State()

    static func snapshot() -> Snapshot {
        sharedState.lock.lock()
        defer { sharedState.lock.unlock() }
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

        let limits = parsePMSetTherm(cachedPMSetOutput())
        s.cpuSpeedLimit = limits.speed
        s.cpuSchedulerLimit = limits.scheduler
        s.cpuAvailableCPUs = limits.available
        return s
    }

    static func hottestTemperature() -> Double? {
        sharedState.lock.lock()
        defer { sharedState.lock.unlock() }
        let hid = temperatureSensors()
        let smc = SMCReader.shared.temperatureSensors()
        return (hid + smc)
            .map(\.value)
            .filter { $0 > 0 && $0 < 120 }
            .max()
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
            case "CPU_Speed_Limit" where (0...100).contains(value): speed = value
            case "CPU_Scheduler_Limit" where (0...100).contains(value): scheduler = value
            case "CPU_Available_CPUs" where (1...1024).contains(value): available = value
            default: continue
            }
        }
        return (speed, scheduler, available)
    }

    private static let pmsetTimeout: TimeInterval = 2

    static func runCommand(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> Data? {
        guard timeout.isFinite, timeout > 0 else { return nil }
        let pipe = Pipe()
        defer {
            pipe.fileHandleForReading.closeFile()
            pipe.fileHandleForWriting.closeFile()
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { return nil }
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments
        task.standardOutput = pipe
        // Diagnostics are intentionally ignored. Sending them to an unread pipe
        // could deadlock a noisy child before it has a chance to terminate.
        task.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do {
            try task.run()
        } catch {
            return nil
        }
        pipe.fileHandleForWriting.closeFile()
        defer {
            if task.isRunning {
                task.terminate()
                if exited.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
                    if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                    _ = exited.wait(timeout: .now() + .milliseconds(500))
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let outputLimit = 4 * 1024 * 1024
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        // Drain while the child runs: waiting for exit first fills the pipe and
        // blocks large writes. Nonblocking reads also bound inherited open pipes.
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                guard output.count + count <= outputLimit else { return nil }
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let result = poll(&descriptor, 1, Int32(max(1, min(50, remaining * 1000))))
                if result < 0 && errno != EINTR { return nil }
            } else {
                return nil
            }
        }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0,
              exited.wait(timeout: .now() + remaining) == .success,
              task.terminationStatus == 0 else { return nil }
        return output
    }

    private static func runPMSetTherm() -> String {
        guard let data = runCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/pmset"),
            arguments: ["-g", "therm"],
            timeout: pmsetTimeout)
        else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func cachedPMSetOutput() -> String {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= sharedState.nextPMSetRefresh else {
            return sharedState.cachedPMSetTherm
        }
        sharedState.cachedPMSetTherm = runPMSetTherm()
        sharedState.nextPMSetRefresh = now + 30
        return sharedState.cachedPMSetTherm
    }

    private static func temperatureSensors() -> [TemperatureSensor] {
        guard let client = sharedState.client,
              let setMatching = HIDPrivateAPI.setMatching,
              let copyServices = HIDPrivateAPI.copyServices,
              let copyEvent = HIDPrivateAPI.copyEvent,
              let getFloatValue = HIDPrivateAPI.getFloatValue
        else { return [] }
        let matching: CFDictionary = [
            "PrimaryUsagePage" as CFString: 0xFF00 as CFNumber,
            "PrimaryUsage" as CFString: 0x05 as CFNumber,
        ] as CFDictionary
        setMatching(client, matching)
        guard let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }

        var values: [String: Double] = [:]
        for service in services {
            guard let event = copyEvent(service, 0x0F, 0, 0)?.takeRetainedValue()
            else { continue }
            let temp = getFloatValue(event, 0x0F << 16)
            guard temp > 0, temp < 120 else { continue }
            let name = sensorName(for: service) ?? "Unknown"
            values[name] = temp
        }
        return values.map { TemperatureSensor(name: $0.key, value: $0.value, source: "IOHID") }
    }

    private static func sensorName(for service: CFTypeRef) -> String? {
        guard let copyProperty = HIDPrivateAPI.copyProperty else { return nil }
        if let product = copyProperty(service, "Product" as CFString)?
            .takeRetainedValue() as? String {
            return product
        }
        if let location = copyProperty(service, "LocationID" as CFString)?
            .takeRetainedValue() as? NSNumber {
            return String(format: "Unknown-FF00-05-%llX", location.uint64Value)
        }
        return nil
    }
}

private final class SMCReader: @unchecked Sendable {
    static let shared = SMCReader()

    private let lock = NSLock()

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
    private var temperatureKeys: [UInt32] = []
    private var keyInfoCache: [UInt32: SMCKeyInfoData] = [:]

    private init() {
        open()
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func temperatureSensors() -> [TemperatureSensor] {
        lock.lock()
        defer { lock.unlock() }
        guard connection != 0 else { return [] }
        if temperatureKeys.isEmpty {
            if keys.isEmpty { keys = readKeys() }
            temperatureKeys = keys.filter { $0 >> 24 == 84 }
        }
        return temperatureKeys.compactMap { key -> TemperatureSensor? in
            guard let sample = readKey(key),
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
        SMCValueDecoder.temperature(data, type: SMCReader.fourCCString(type))
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
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var cachedService: io_object_t = 0

        deinit {
            if cachedService != 0 { IOObjectRelease(cachedService) }
        }
    }

    private static let sharedState = State()

    /// Returns the GPU breakdown in one registry read:
    ///   - raw:     "Device Utilization %" (total busy, incl. graphics/display rendering) — matches AM
    ///   - render:  "Renderer Utilization %" (graphics / display rendering)
    ///
    /// Key observation: graphics/display rendering drives Device and Renderer together
    /// (Device ≈ Renderer), while Metal compute (embeddings) drives Device far
    /// above Renderer. So `Device − Renderer` isolates real compute — a brief
    /// menu/Mission-Control composite ≈ 0, an embedding stays high — far better
    /// than a fixed baseline that big menu renders could exceed.
    static func stats() -> (raw: Double, render: Double, subtractRenderer: Bool, available: Bool) {
        sharedState.lock.lock()
        defer { sharedState.lock.unlock() }
        if sharedState.cachedService == 0 { sharedState.cachedService = findAccelerator() }
        guard sharedState.cachedService != 0 else { return (0, 0, true, false) }
        guard let perf = perfStats(sharedState.cachedService) else {
            IOObjectRelease(sharedState.cachedService)  // service vanished — re-match next time
            sharedState.cachedService = 0
            return (0, 0, true, false)
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
        -> (raw: Double, render: Double, subtractRenderer: Bool, available: Bool) {
        func percent(_ key: String) -> Double? {
            guard let value = perf[key] as? NSNumber else { return nil }
            let number = value.doubleValue
            guard number.isFinite else { return nil }
            return max(0, min(100, number))
        }

        let renderValue = percent("Renderer Utilization %")
        let render = renderValue ?? 0
        // "Device Utilization %" is the right signal: 0 at idle, ~100 under Metal
        // compute (embeddings). Do NOT fold in "Renderer"/"Tiler" — those read
        // ~10-15% just from normal menu-bar compositing (including our own cat),
        // which would keep the cat sprinting at idle and waste CPU.
        if let raw = percent("Device Utilization %") {
            return (raw, render, true, true)
        }

        // Best-effort display fallback only. These GPUs do not expose enough
        // information to guarantee Device−Renderer compute isolation, so don't
        // subtract renderer again from a value that may already be graphics-only.
        if let activity = percent("GPU Activity(%)") {
            return (activity, render, false, true)
        }
        if let tiler = percent("Tiler Utilization %") {
            return (max(render, tiler), render, false, true)
        }
        if let renderValue {
            return (renderValue, renderValue, false, true)
        }
        return (0, 0, false, false)
    }
}
