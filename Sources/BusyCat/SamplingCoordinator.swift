import Foundation

/// Main-thread presentation history belongs to one uninterrupted awake session.
struct SamplingSession {
    private(set) var asleep = false
    private(set) var generation: UInt64 = 0
    private(set) var cpuHistory: [Double] = []

    mutating func sleep() {
        asleep = true
        generation &+= 1
        cpuHistory.removeAll(keepingCapacity: true)
    }

    mutating func wake() {
        asleep = false
        generation &+= 1
        cpuHistory.removeAll(keepingCapacity: true)
    }

    func accepts(_ generation: UInt64) -> Bool {
        !asleep && self.generation == generation
    }

    mutating func appendCPU(_ value: Double?) {
        guard !asleep else { return }
        MetricMath.updateHistory(&cpuHistory, sample: value)
    }
}

struct SampleFields: OptionSet, Sendable {
    let rawValue: UInt8

    static let cpu = SampleFields(rawValue: 1 << 0)
    static let gpu = SampleFields(rawValue: 1 << 1)
    static let memory = SampleFields(rawValue: 1 << 2)
    static let temperature = SampleFields(rawValue: 1 << 3)
    static let all: SampleFields = [.cpu, .gpu, .memory, .temperature]

    static func required(
        driver: SpeedDriver,
        statusTextMode: StatusTextMode,
        memoryFish: Bool
    ) -> SampleFields {
        var fields: SampleFields
        switch driver {
        case .busiest: fields = [.cpu, .gpu]
        case .cpu: fields = [.cpu]
        case .gpu: fields = [.gpu]
        case .memory: fields = [.memory]
        }

        switch statusTextMode {
        case .cpu: fields.insert(.cpu)
        case .gpu: fields.insert(.gpu)
        case .memory: fields.insert(.memory)
        case .temperature: fields.insert(.temperature)
        case .off, .driver, .thermal: break
        }
        if memoryFish { fields.insert(.memory) }
        return fields
    }
}

/// Owns the stateful sampler and confines every read to one serial queue. The
/// UI receives completed snapshots on the main queue and never waits on IOKit,
/// SMC key enumeration, disk queries, or external processes.
final class SamplingCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dlfnek.busycat.sampling", qos: .utility)
    private let sampler = SystemSampler()

    func sample(
        full: Bool,
        fields: SampleFields,
        completion: @escaping @MainActor @Sendable (Metrics) -> Void
    ) {
        queue.async { [sampler] in
            var sampled = full ? sampler.sampleAll() : sampler.sampleLight(fields: fields)
            if !full && fields.contains(.temperature) {
                sampled.thermalTemp = sampler.temperatureForStatusText()
            }
            let metrics = sampled
            DispatchQueue.main.async {
                completion(metrics)
            }
        }
    }

    func resetFastHistory() {
        queue.async { [sampler] in
            sampler.resetFastHistory()
        }
    }
}
