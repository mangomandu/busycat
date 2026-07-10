import Foundation

/// Owns the stateful sampler and confines every read to one serial queue. The
/// UI receives completed snapshots on the main queue and never waits on IOKit,
/// SMC key enumeration, disk queries, or external processes.
final class SamplingCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dlfnek.busycat.sampling", qos: .utility)
    private let sampler = SystemSampler()

    func sample(
        full: Bool,
        includeTemperature: Bool,
        completion: @escaping (Metrics) -> Void
    ) {
        queue.async { [sampler] in
            var metrics = full ? sampler.sampleAll() : sampler.sampleLight()
            if !full && includeTemperature {
                metrics.thermalTemp = sampler.temperatureForStatusText()
            }
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
