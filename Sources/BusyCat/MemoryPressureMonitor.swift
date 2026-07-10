import Foundation

enum MemoryPressureLevel: Int, Sendable {
    case normal
    case warning
    case critical
}

/// Tracks macOS' system-wide memory pressure state using the public Dispatch API.
/// The event source reports meaningful pressure states rather than a made-up
/// percentage derived from individual VM counters.
final class MemoryPressureMonitor {
    private let lock = NSLock()
    private var currentLevel: MemoryPressureLevel = .normal
    private let queue = DispatchQueue(label: "com.dlfnek.busycat.memory-pressure", qos: .utility)
    private lazy var source = DispatchSource.makeMemoryPressureSource(
        eventMask: [.normal, .warning, .critical],
        queue: queue)

    init() {
        source.setEventHandler { [weak self] in
            self?.pressureChanged()
        }
        source.activate()
    }

    deinit {
        source.cancel()
    }

    var level: MemoryPressureLevel {
        lock.lock()
        defer { lock.unlock() }
        return currentLevel
    }

    private func pressureChanged() {
        let events = source.data
        let next: MemoryPressureLevel
        if events.contains(.critical) {
            next = .critical
        } else if events.contains(.warning) {
            next = .warning
        } else {
            next = .normal
        }

        lock.lock()
        currentLevel = next
        lock.unlock()
    }
}
