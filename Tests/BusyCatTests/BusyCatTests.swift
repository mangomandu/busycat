import Foundation
import Testing
@testable import BusyCat

@Suite("BusyCat regression tests")
struct BusyCatTests {
    @Test @MainActor func embeddedCatFramesDecodeAtExpectedSize() {
        let frames = CatFrames.load(height: 18)
        #expect(frames.count == 5)
        #expect(frames.allSatisfy { $0.size.width == 28 && $0.size.height == 18 })
        #expect(CatFrames.load(height: 18, flipped: true).count == 5)
    }

    @Test func diskUsageFallsBackWhenImportantCapacityIsZero() {
        let result = MetricMath.diskUsage(
            total: 1_000, importantAvailable: 0, regularAvailable: 800)!
        #expect(abs(result.percent - 20) < 0.0001)
        #expect(result.used == 200)
    }

    @Test func diskUsageAllowsPurgeableCapacityAndClampsToTotal() {
        let result = MetricMath.diskUsage(
            total: 1_000, importantAvailable: 1_200, regularAvailable: 800)!
        #expect(result.percent == 0)
        #expect(result.used == 0)
    }

    @Test func diskUsageTreatsMissingAvailabilityAsUnavailable() {
        #expect(MetricMath.diskUsage(
            total: 1_000, importantAvailable: nil, regularAvailable: nil) == nil)
        #expect(MetricMath.diskUsage(
            total: 1_000, importantAvailable: -1, regularAvailable: -1) == nil)
    }

    @Test func cpuCounterDeltaHandlesUInt32Wrap() {
        #expect(MetricMath.counterDelta(
            current: 5, previous: UInt32.max - 4) == 10)
    }

    @Test func speedCurveBounds() {
        #expect(abs(SpeedCurve.interval(forUsage: 0) - 0.4) < 0.0001)
        #expect(abs(SpeedCurve.interval(forUsage: 100) - 0.02) < 0.0001)
        #expect(abs(SpeedCurve.interval(forUsage: 500) - 0.02) < 0.0001)
        #expect(abs(SpeedCurve.interval(forUsage: 100, maximumFPS: 20) - 0.05) < 0.0001)
        #expect(abs(SpeedCurve.interval(forUsage: .nan) - 0.4) < 0.0001)
        #expect(abs(SpeedCurve.interval(forUsage: 100, maximumFPS: .nan) - 0.02) < 0.0001)
    }

    @Test func speedUsageMatchesInvertSetting() {
        #expect(MetricMath.speedUsage(base: 80, inverted: false) == 80)
        #expect(MetricMath.speedUsage(base: 80, inverted: true) == 20)
    }

    @Test func metricHistoryClearsAcrossUnsampledGapsAndKeepsLimit() {
        var history = [1.0, 2.0]
        MetricMath.updateHistory(&history, sample: nil, limit: 3)
        #expect(history.isEmpty)

        for value in 1...4 {
            MetricMath.updateHistory(&history, sample: Double(value), limit: 3)
        }
        #expect(history == [2, 3, 4])

        MetricMath.updateHistory(&history, sample: 5, limit: 0)
        #expect(history.isEmpty)
        MetricMath.updateHistory(&history, sample: .nan)
        #expect(history.isEmpty)
    }

    @Test func busiestDriverIgnoresUnavailableGPU() {
        var metrics = Metrics()
        metrics.cpu = 12
        metrics.gpuCompute = 90
        metrics.gpuAvailable = false
        #expect(SpeedDriver.busiest.value(metrics) == 12)

        metrics.gpuAvailable = true
        #expect(SpeedDriver.busiest.value(metrics) == 90)
    }

    @Test func memoryFishGaugeClamps() {
        #expect(MetricMath.memoryFishLevel(pressure: .normal) == 0)
        #expect(MetricMath.memoryFishLevel(pressure: .warning) == 3)
        #expect(MetricMath.memoryFishLevel(pressure: .critical) == 5)
        #expect(MetricMath.memoryFishLevel(pressure: .critical, maxFish: 0) == 0)
    }

    @Test func deviceGPUCountersAndComputePath() {
        let result = GPUReader.counters(from: [
            "Device Utilization %": 80,
            "Renderer Utilization %": 15,
        ])
        #expect(result.raw == 80)
        #expect(result.render == 15)
        #expect(result.subtractRenderer)
        #expect(result.available)
        #expect(MetricMath.gpuCompute(raw: result.raw, render: result.render) == 65)
    }

    @Test func gpuComputeClampsRendererAboveRaw() {
        #expect(MetricMath.gpuCompute(raw: 10, render: 20) == 0)
    }

    @Test func legacyGPUFallbackDoesNotSubtractItselfToZero() {
        let activity = GPUReader.counters(from: [
            "GPU Activity(%)": 32,
            "Renderer Utilization %": 32,
        ])
        #expect(activity.raw == 32)
        #expect(activity.render == 32)
        #expect(!activity.subtractRenderer)
        #expect(activity.available)

        let pipeline = GPUReader.counters(from: [
            "Renderer Utilization %": 32,
            "Tiler Utilization %": 10,
        ])
        #expect(pipeline.raw == 32)
        #expect(pipeline.render == 32)
        #expect(!pipeline.subtractRenderer)
        #expect(pipeline.available)
    }

    @Test func missingGPUCountersReportUnavailable() {
        let result = GPUReader.counters(from: [:])
        #expect(!result.available)

        let malformed = GPUReader.counters(from: [
            "Device Utilization %": Double.nan,
            "Renderer Utilization %": "unknown",
        ])
        #expect(!malformed.available)
    }

    @Test func numericVersionComparison() {
        #expect(Updater.isNewer("1.10", than: "1.9"))
        #expect(!Updater.isNewer("1.9", than: "1.10"))
        #expect(!Updater.isNewer("1.0", than: "1.0"))
        #expect(!Updater.isNewer("1.0.0", than: "1.0"))
        #expect(!Updater.isNewer("1.0-beta", than: "1.0"))
        #expect(!Updater.isNewer("1.0+build.2", than: "1.0+build.1"))
        #expect(Updater.isNewer("1.0", than: "1.0-rc.1"))
        #expect(Updater.isNewer("1.0-rc.10", than: "1.0-rc.2"))
        #expect(Updater.isNewer("1.0-rc-2", than: "1.0-rc-1"))
    }

    @Test func malformedSemanticVersionsFailClosed() throws {
        for tag in ["1.2+", "1.2+build+extra", "1.02", "1.2.3.4", "1.2-rc_1", "1.2-01"] {
            let data = try JSONSerialization.data(withJSONObject: ["tag_name": tag])
            #expect(Updater.interpretLatestRelease(
                statusCode: 200, data: data, currentVersion: "1.1") == .failed)
        }
        #expect(!Updater.isNewer("1.2-999999999999999999999999", than: "1.1"))
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

    /// GitHub uses the same 404 for "no releases", a missing repository, and a
    /// renamed repository, so the updater cannot safely call it up to date.
    @Test func updateResponseTreats404AsFailure() {
        let body = Data(#"{"message":"Not Found","status":"404"}"#.utf8)
        #expect(Updater.interpretLatestRelease(
            statusCode: 404, data: body, currentVersion: "1.0") == .failed)
        #expect(Updater.interpretLatestRelease(
            statusCode: 404, data: nil, currentVersion: "1.0") == .failed)
    }

    @Test func invalidReleaseVersionFailsClosed() throws {
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": "next"])
        #expect(Updater.interpretLatestRelease(
            statusCode: 200, data: data, currentVersion: "1.0") == .failed)
    }

    @Test func lightSamplingFollowsActiveFeatures() {
        #expect(SampleFields.required(
            driver: .busiest, statusTextMode: .off, memoryFish: false) == [.cpu, .gpu])
        #expect(SampleFields.required(
            driver: .cpu, statusTextMode: .memory, memoryFish: false) == [.cpu, .memory])
        #expect(SampleFields.required(
            driver: .gpu, statusTextMode: .temperature, memoryFish: true)
            == [.gpu, .memory, .temperature])
    }

    @Test func pmsetThermalLimitsParseWithWhitespace() {
        let result = ThermalReader.parsePMSetTherm("""
            CPU_Scheduler_Limit = 100
            CPU_Available_CPUs  = 10
            CPU_Speed_Limit     = 87
            """)
        #expect(result.scheduler == 100)
        #expect(result.available == 10)
        #expect(result.speed == 87)
    }

    @Test func pmsetThermalLimitsRejectImpossibleValues() {
        let result = ThermalReader.parsePMSetTherm("""
            CPU_Scheduler_Limit = 101
            CPU_Available_CPUs  = 2048
            CPU_Speed_Limit     = -1
            """)
        #expect(result.scheduler == nil)
        #expect(result.available == nil)
        #expect(result.speed == nil)
    }

    @Test func externalThermalCommandHasTimeout() {
        let started = Date()
        let result = ThermalReader.runCommand(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"],
            timeout: 0.05)
        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }
}
