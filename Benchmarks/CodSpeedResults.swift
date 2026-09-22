import Foundation

// Walltime result format shared by CodSpeed's Rust and C++ integrations.
enum CodSpeedResults {
    static let integrationName = "rill-swift"
    static let integrationVersion = "1.0.0"

    static func benchmark(name: String, uri: String, samples: [Double]) -> [String: Any] {
        precondition(samples.count > 1 && samples.allSatisfy { $0 > 0 && $0.isFinite })
        let sorted = samples.sorted()
        let total = samples.reduce(0, +)
        let mean = total / Double(samples.count)
        let variance = samples.reduce(0) { $0 + pow($1 - mean, 2) } / Double(samples.count - 1)
        let stdev = sqrt(variance)
        func quantile(_ fraction: Double) -> Double {
            let position = fraction * Double(sorted.count - 1)
            let lower = Int(position)
            let upper = min(lower + 1, sorted.count - 1)
            return sorted[lower] + (position - Double(lower)) * (sorted[upper] - sorted[lower])
        }
        let q1 = quantile(0.25)
        let q3 = quantile(0.75)
        let iqr = q3 - q1
        return [
            "name": name, "uri": uri,
            "config": ["max_rounds": samples.count],
            "stats": [
                "min_ns": sorted[0], "max_ns": sorted[sorted.count - 1],
                "mean_ns": mean, "stdev_ns": stdev,
                "q1_ns": q1, "median_ns": quantile(0.5), "q3_ns": q3,
                "rounds": samples.count, "total_time": total / 1e9,
                "iqr_outlier_rounds": samples.filter { $0 < q1 - 1.5 * iqr || $0 > q3 + 1.5 * iqr }.count,
                "stdev_outlier_rounds": samples.filter { abs($0 - mean) > 3 * stdev }.count,
                "iter_per_round": 1, "warmup_iters": 1,
            ] as [String: Any],
        ]
    }

    static func write(_ benchmarks: [[String: Any]]) throws {
        guard let profileFolder = ProcessInfo.processInfo.environment["CODSPEED_PROFILE_FOLDER"] else {
            fatalError("CodSpeed did not provide a result directory")
        }
        let directory = URL(fileURLWithPath: profileFolder).appendingPathComponent("results")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result: [String: Any] = [
            "creator": ["name": integrationName, "version": integrationVersion, "pid": getpid()] as [String: Any],
            "instrument": ["type": "walltime"], "benchmarks": benchmarks,
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("\(getpid()).json"), options: [.atomic])
    }
}
