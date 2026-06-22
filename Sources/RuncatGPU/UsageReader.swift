import Foundation
import IOKit
import IOKit.ps

/// One snapshot of everything RunCat-GPU monitors.
struct Metrics {
    var cpu: Double = 0          // %
    var gpu: Double = 0          // %
    var memory: Double = 0       // % used
    var disk: Double = 0         // % used on "/"
    var netDown: Double = 0      // bytes/s
    var netUp: Double = 0        // bytes/s
    var battery: Int? = nil      // % (nil on desktop Macs)
    var charging: Bool = false
}

/// Samples all system metrics. Holds the small bit of state needed to turn the
/// kernel's monotonically-increasing counters (CPU ticks, interface bytes) into
/// per-interval rates.
final class SystemSampler {
    // CPU tick deltas
    private var prevCPUBusy: UInt64 = 0
    private var prevCPUTotal: UInt64 = 0
    private var cpuPrimed = false
    // Network byte deltas
    private var prevRx: UInt64 = 0
    private var prevTx: UInt64 = 0
    private var prevNetTime: Double = 0
    private var netPrimed = false

    /// Cheap metrics needed every second to drive the cat (CPU/GPU/memory are all
    /// single fast kernel calls). Used while the menu is closed — i.e. ~always.
    func sampleLight() -> Metrics {
        var m = Metrics()
        m.cpu = cpu()
        m.gpu = GPUReader.usage()
        m.memory = memoryPercent()
        return m
    }

    /// Full snapshot including the costlier reads (disk volume query, getifaddrs,
    /// IOKit power source). Only worth doing while the menu is actually open, since
    /// those extra rows aren't visible otherwise.
    func sampleAll() -> Metrics {
        var m = sampleLight()
        m.disk = diskPercent()
        let net = network()
        m.netDown = net.down
        m.netUp = net.up
        let bat = battery()
        m.battery = bat.percent
        m.charging = bat.charging
        return m
    }

    // MARK: CPU — busy% over the interval (HOST_CPU_LOAD_INFO tick delta)

    private func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reb, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = UInt64(info.cpu_ticks.0)     // USER
        let system = UInt64(info.cpu_ticks.1)   // SYSTEM
        let idle = UInt64(info.cpu_ticks.2)     // IDLE
        let nice = UInt64(info.cpu_ticks.3)     // NICE
        // Match RunCat exactly: busy = system + user (nice excluded from the
        // numerator but kept in the total), capped at 99.9%.
        let busy = user &+ system
        let total = user &+ system &+ idle &+ nice

        defer { prevCPUBusy = busy; prevCPUTotal = total; cpuPrimed = true }
        guard cpuPrimed else { return 0 }
        let dBusy = Double(busy &- prevCPUBusy)
        let dTotal = Double(total &- prevCPUTotal)
        guard dTotal > 0 else { return 0 }
        return max(0, min(99.9, dBusy / dTotal * 100))
    }

    // MARK: Memory — (active + wired + compressed) / total

    private func memoryPercent() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reb, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)) * pageSize
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        guard total > 0 else { return 0 }
        return min(100, Double(used) / Double(total) * 100)
    }

    // MARK: Disk — used% of the root volume

    private func diskPercent() -> Double {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
            let total = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacity,
            total > 0
        else { return 0 }
        return max(0, min(100, Double(total - avail) / Double(total) * 100))
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
        return (down, up)
    }

    // MARK: Battery — % and charging state (nil on desktops)

    private func battery() -> (percent: Int?, charging: Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, false) }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            let cur = desc[kIOPSCurrentCapacityKey] as? Int
            let mx = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            if let c = cur, mx > 0 {
                return (Int((Double(c) / Double(mx) * 100).rounded()), charging)
            }
        }
        return (nil, false)
    }
}

/// Reads GPU utilization from the IOKit registry (no sudo needed on Apple
/// Silicon). Returns the highest busy% across all accelerators.
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
/// We take the max of all three so both compute and graphics load register, and
/// fall back to "GPU Activity(%)" on older / third-party GPUs.
enum GPUReader {
    // The accelerator service is matched once and cached: re-matching every second
    // is wasteful. We also read only the "PerformanceStatistics" property instead
    // of copying the accelerator's entire (large) property set each tick.
    private static var cachedService: io_object_t = 0

    static func usage() -> Double {
        if cachedService == 0 { cachedService = findAccelerator() }
        guard cachedService != 0 else { return 0 }
        guard let perf = perfStats(cachedService) else {
            IOObjectRelease(cachedService)  // service vanished — re-match next time
            cachedService = 0
            return 0
        }
        return min(100, deviceUsage(perf))
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

    private static func deviceUsage(_ perf: [String: Any]) -> Double {
        // "Device Utilization %" is the right signal: 0 at idle, ~100 under Metal
        // compute (embeddings). Do NOT fold in "Renderer"/"Tiler" — those read
        // ~10-15% just from normal menu-bar compositing (including our own cat),
        // which would keep the cat sprinting at idle and waste CPU.
        if let device = perf["Device Utilization %"] as? Int { return Double(device) }
        // Fallback for GPUs lacking that key (older / third-party).
        var best = 0.0
        var found = false
        for key in ["Renderer Utilization %", "Tiler Utilization %"] {
            if let v = perf[key] as? Int {
                best = max(best, Double(v))
                found = true
            }
        }
        if found { return best }
        if let activity = perf["GPU Activity(%)"] as? Int { return Double(activity) }
        return 0
    }
}
