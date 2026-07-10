import Foundation

/// Pure calculations shared by the system readers and their regression tests.
enum MetricMath {
    static func diskUsage(
        total: Int64,
        importantAvailable: Int64?,
        regularAvailable: Int64?
    ) -> (percent: Double, used: Double, total: Double) {
        guard total > 0 else { return (0, 0, 0) }

        // `volumeAvailableCapacityForImportantUsage` can incorrectly report zero
        // on some macOS/APFS combinations. Regular available capacity is a valid
        // lower-bound fallback; normally the "important" value is the larger one.
        var candidates: [Int64] = []
        if let importantAvailable, importantAvailable >= 0 {
            candidates.append(importantAvailable)
        }
        if let regularAvailable, regularAvailable >= 0 {
            candidates.append(regularAvailable)
        }
        let available = candidates.max() ?? 0
        let clampedAvailable = min(total, available)
        let used = Double(total - clampedAvailable)
        let totalDouble = Double(total)
        return (min(100, used / totalDouble * 100), used, totalDouble)
    }

    /// Mach CPU counters are 32-bit and wrap independently.
    static func counterDelta(current: UInt32, previous: UInt32) -> UInt64 {
        UInt64(current &- previous)
    }

    /// Apple Silicon compute load after removing renderer/compositor activity.
    static func gpuCompute(raw: Double, render: Double) -> Double {
        max(0, raw - render)
    }

    static func speedUsage(base: Double, inverted: Bool) -> Double {
        inverted ? 100 - base : base
    }

    /// RAM fish gauge level from macOS' real system memory-pressure state.
    static func memoryFishLevel(pressure: MemoryPressureLevel, maxFish: Int = 5) -> Int {
        guard maxFish > 0 else { return 0 }
        switch pressure {
        case .normal:
            return 0
        case .warning:
            return max(1, Int((Double(maxFish) * 0.6).rounded()))
        case .critical:
            return maxFish
        }
    }
}

enum SpeedCurve {
    /// Half RunCat's animation rate: about 2.5 fps idle to 50 fps at 100%.
    static func interval(forUsage usage: Double, maximumFPS: Double = 50) -> TimeInterval {
        let base = 0.4 / max(1.0, min(20.0, usage / 5.0))
        guard maximumFPS > 0 else { return base }
        return max(base, 1 / maximumFPS)
    }
}
