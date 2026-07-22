import Foundation

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
