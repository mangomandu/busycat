import Foundation
import IOKit
import SystemConfiguration

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
    // Slow/heavy metrics (disk, network type+IP, battery) refreshed every ~5s
    // while the menu is open, not every tick — they barely change second-to-second.
    private var slowTick = 0
    private var slowPrimed = false
    private var cDisk: (percent: Double, used: Double, total: Double) = (0, 0, 0)
    private var cNet: (type: String, ip: String) = ("—", "—")
    private var cBat: (percent: Double?, charging: Bool, onAC: Bool,
                       health: Double?, cycles: Int?, temp: Double?) = (nil, false, false, nil, nil, nil)

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
