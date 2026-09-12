import Foundation
import AppKit
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

    @Test func externalCommandDrainsLargeOutputAndRejectsOverflow() {
        let head = URL(fileURLWithPath: "/usr/bin/head")
        let output = ThermalReader.runCommand(
            executableURL: head, arguments: ["-c", "1048576", "/dev/zero"], timeout: 3)
        #expect(output?.count == 1_048_576)
        #expect(output?.allSatisfy { $0 == 0 } == true)
        #expect(ThermalReader.runCommand(
            executableURL: head, arguments: ["-c", "5242880", "/dev/zero"], timeout: 3) == nil)
    }

    @Test func externalCommandHandlesEmptyFailureAndInheritedPipe() {
        let shell = URL(fileURLWithPath: "/bin/sh")
        #expect(ThermalReader.runCommand(
            executableURL: shell, arguments: ["-c", "exit 0"], timeout: 1) == Data())
        #expect(ThermalReader.runCommand(
            executableURL: shell, arguments: ["-c", "printf partial; exit 1"], timeout: 1) == nil)
        let started = Date()
        #expect(ThermalReader.runCommand(
            executableURL: shell, arguments: ["-c", "sleep 1 & exit 0"], timeout: 0.05) == nil)
        #expect(Date().timeIntervalSince(started) < 0.8)
        #expect(ThermalReader.runCommand(
            executableURL: shell, arguments: [], timeout: .nan) == nil)
    }

    @Test(arguments: ["match", "mismatch", "missing", "local", "metadata", "badArguments"])
    func releaseArtifactChecksumValidation(scenario: String) throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("BusyCat checksum \(UUID().uuidString)")
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        try manager.createDirectory(at: fixture.appendingPathComponent("tools"), withIntermediateDirectories: true)
        try manager.createDirectory(at: fixture.appendingPathComponent("Casks"), withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = fixture.appendingPathComponent("tools/check_release_consistency.sh")
        try manager.copyItem(at: root.appendingPathComponent("tools/check_release_consistency.sh"), to: script)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "9.8.7"
        ], format: .xml, options: 0)
        try plist.write(to: fixture.appendingPathComponent("Info.plist"))
        let assetName = "BusyCat-9.8.7-macOS.dmg"
        for name in ["README.md", "README.ko.md"] {
            try assetName.write(to: fixture.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // SHA-256 of the three bytes "abc"; no DMG mounting is needed to test hashing.
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let cask = """
          version "9.8.7"
          sha256 "\(sha)"
          depends_on arch: :arm64
          depends_on macos: :ventura
        """
        try cask.write(to: fixture.appendingPathComponent("Casks/busycat.rb"), atomically: true, encoding: .utf8)
        let artifact = fixture.appendingPathComponent(
            scenario == "local" ? "BusyCat-9.8.7-macOS-local.dmg" : assetName)
        if scenario != "missing" && scenario != "metadata" {
            try Data((scenario == "mismatch" ? "modified" : "abc").utf8).write(to: artifact)
        }
        var args = [script.path]
        if scenario == "badArguments" {
            args += ["--artifact"]
        } else if scenario != "metadata" {
            args += ["--artifact", artifact.path]
        }
        let result = ThermalReader.runCommand(
            executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: args, timeout: 3)
        if scenario == "match" || scenario == "metadata" {
            let output = String(decoding: try #require(result), as: UTF8.self)
            #expect(output.contains(scenario == "match"
                ? "SHA-256 matches" : "SHA-256 not checked"))
        } else {
            #expect(result == nil)
        }
    }

    @Test func localDMGPathsCannotReplaceReleaseArtifacts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("make_dmg.sh")
        let source = try String(contentsOf: script, encoding: .utf8)
        // Execute only argument/path validation, never build, mount, sign or notarize.
        let boundary = try #require(source.range(of: "\n./tools/check_release_consistency.sh"))
        let prefix = "BUSYCAT_SIGN_IDENTITY=test-only\nBUSYCAT_NOTARY_PROFILE=test-only\n"
            + source[..<boundary.lowerBound]
            + "\nprintf '%s\\n' \"$DMG_NAME\" \"$STAGE_DIR\" \"$TEMP_DMG\" \"$PENDING_DMG\"\n"
        func paths(_ args: [String]) throws -> [String] {
            let data = try #require(ThermalReader.runCommand(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", prefix, script.path] + args, timeout: 2))
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        let release = try paths([])
        let local = try paths(["--local"])
        #expect(release.count == 4 && local.count == 4)
        #expect(Set(release).isDisjoint(with: Set(local)))
        #expect(release.first?.hasSuffix("-macOS.dmg") == true)
        #expect(local.first?.hasSuffix("-macOS-local.dmg") == true)
    }

    @Test func updateMenuPresentationReflectsCheckingAndAvailability() {
        let checking = UpdateMenuPresentation(checking: true, availableVersion: nil)
        #expect(!checking.enabled)
        let finished = UpdateMenuPresentation(checking: false, availableVersion: nil)
        #expect(finished.enabled)
        #expect(finished.title != checking.title)
        let available = UpdateMenuPresentation(checking: false, availableVersion: "1.2.0")
        #expect(available.enabled)
        #expect(available.title.contains("1.2.0"))
    }

    @Test func sleepInvalidatesHistoryAndInFlightSamples() {
        var session = SamplingSession()
        let beforeSleep = session.generation
        session.appendCPU(70)
        session.sleep()
        #expect(session.cpuHistory.isEmpty)
        #expect(!session.accepts(beforeSleep))
        session.appendCPU(90)
        #expect(session.cpuHistory.isEmpty)
        session.wake()
        #expect(!session.accepts(beforeSleep))
        #expect(session.accepts(session.generation))
        session.appendCPU(10)
        #expect(session.cpuHistory == [10])
        let beforeSecondWake = session.generation
        session.wake()
        #expect(session.cpuHistory.isEmpty)
        #expect(!session.accepts(beforeSecondWake))
    }

    @Test func cpuSamplingGapPrimesFreshCountersAndAverage() {
        let sampler = SystemSampler()
        #expect(sampler.updateCPU(user: 0, system: 0, idle: 0, nice: 0).total == 0)
        #expect(sampler.updateCPU(user: 80, system: 20, idle: 0, nice: 0).total == 100)
        _ = sampler.sampleLight(fields: [])
        // Counter changes throughout the unsampled interval are discarded.
        #expect(sampler.updateCPU(user: 800, system: 200, idle: 9000, nice: 0).total == 0)
        #expect(sampler.updateCPU(user: 800, system: 200, idle: 9000, nice: 0).total == 0)
        let fresh = sampler.updateCPU(user: 810, system: 200, idle: 9090, nice: 0)
        #expect(fresh.total == 10)
        #expect(fresh.user == 10 && fresh.system == 0)
        sampler.resetFastHistory()
        #expect(sampler.updateCPU(user: 1000, system: 1000, idle: 10000, nice: 0).total == 0)
    }

    @Test func gpuSamplingGapDiscardsOldAverage() {
        let sampler = SystemSampler()
        var metrics = Metrics()
        sampler.updateGPU((90, 10, true, true), into: &metrics)
        #expect(metrics.gpuCompute == 80)
        _ = sampler.sampleLight(fields: [])
        sampler.updateGPU((15, 5, true, true), into: &metrics)
        #expect(metrics.gpuRaw == 15 && metrics.gpuRender == 5)
        #expect(metrics.gpuCompute == 10)
        sampler.resetFastHistory()
        sampler.updateGPU((30, 0, true, true), into: &metrics)
        #expect(metrics.gpuCompute == 30)
        sampler.updateGPU((0, 0, true, false), into: &metrics)
        sampler.updateGPU((12, 12, false, true), into: &metrics)
        #expect(metrics.gpuAvailable && metrics.gpuCompute == 12)
    }

    @Test @MainActor func ipv6SubtextWrapsAndExpandsPanel() {
        let view = StatsView()
        for label in ["로컬 IP", "Local IP"] {
            #expect(view.subtextHeight("\(label): 192.168.0.2") == 15)
            #expect(view.subtextHeight("\(label): ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff") > 15)
        }
        var metrics = Metrics()
        metrics.localIP = "192.168.0.2"
        view.update(metrics, history: [])
        let shortHeight = view.frame.height
        metrics.localIP = "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
        view.update(metrics, history: [])
        #expect(view.frame.width == 250)
        #expect(view.frame.height > shortHeight)
    }

    @Test func smcTemperaturePreservesSignedFixedPointAndFloat() {
        #expect(SMCValueDecoder.temperature([0, 0xF6], type: "sp78") == -10)
        #expect(SMCValueDecoder.temperature([0x80, 0xFF], type: "sp78") == -0.5)
        #expect(SMCValueDecoder.temperature([0x80, 42], type: "sp78") == 42.5)
        #expect(SMCValueDecoder.temperature([0, 0], type: "sp78") == 0)
        #expect(SMCValueDecoder.temperature([0x42, 0x2A, 0, 0], type: "flt ") == 42.5)
        #expect(SMCValueDecoder.temperature([0], type: "sp78") == nil)
        #expect(SMCValueDecoder.temperature([0], type: "flt ") == nil)
        #expect(SMCValueDecoder.temperature([0, 0], type: "unknown") == nil)
    }
}
