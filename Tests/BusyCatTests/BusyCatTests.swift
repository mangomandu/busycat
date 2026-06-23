import Foundation
import Testing
@testable import BusyCat

@Suite("BusyCat regression tests")
struct BusyCatTests {
    @Test func diskUsageFallsBackWhenImportantCapacityIsZero() {
        let result = MetricMath.diskUsage(
            total: 1_000, importantAvailable: 0, regularAvailable: 800)
        #expect(abs(result.percent - 20) < 0.0001)
        #expect(result.used == 200)
    }

    @Test func diskUsageAllowsPurgeableCapacityAndClampsToTotal() {
        let result = MetricMath.diskUsage(
            total: 1_000, importantAvailable: 1_200, regularAvailable: 800)
        #expect(result.percent == 0)
        #expect(result.used == 0)
    }

    @Test func cpuCounterDeltaHandlesUInt32Wrap() {
        #expect(MetricMath.counterDelta(
            current: 5, previous: UInt32.max - 4) == 10)
    }

    @Test func speedCurveBounds() {
        #expect(abs(SpeedCurve.interval(forUsage: 0) - 0.4) < 0.0001)
        #expect(abs(SpeedCurve.interval(forUsage: 100) - 0.02) < 0.0001)
        #expect(abs(SpeedCurve.interval(forUsage: 500) - 0.02) < 0.0001)
    }

    @Test func deviceGPUUsageSubtractsRenderer() {
        let result = GPUReader.utilization(from: [
            "Device Utilization %": 80,
            "Renderer Utilization %": 15,
        ])
        #expect(result.compute == 65)
        #expect(result.raw == 80)
        #expect(result.render == 15)
    }

    @Test func legacyGPUFallbackDoesNotSubtractItselfToZero() {
        let result = GPUReader.utilization(from: [
            "Renderer Utilization %": 35,
            "Tiler Utilization %": 20,
        ])
        #expect(result.compute == 35)
        #expect(result.raw == 35)
    }

    @Test func numericVersionComparison() {
        #expect(Updater.isNewer("1.10", than: "1.9"))
        #expect(!Updater.isNewer("1.9", than: "1.10"))
        #expect(!Updater.isNewer("1.0", than: "1.0"))
    }

    @Test func updateResponseDistinguishesUpToDateAndFailure() throws {
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v1.0"])
        #expect(Updater.interpretLatestRelease(
            statusCode: 200, data: data, currentVersion: "1.0") == .upToDate)
        #expect(Updater.interpretLatestRelease(
            statusCode: 503, data: data, currentVersion: "1.0") == .failed)
        #expect(Updater.interpretLatestRelease(
            statusCode: 200, data: Data("{}".utf8), currentVersion: "1.0") == .failed)
    }

    @Test func updateResponseFindsNewVersion() throws {
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": "V1.2"])
        #expect(Updater.interpretLatestRelease(
            statusCode: 200, data: data, currentVersion: "1.1") == .updateAvailable("1.2"))
    }
}
