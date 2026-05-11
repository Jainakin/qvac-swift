// QVACBench — measures the round-trip latency of `heartbeat` from the Swift client.
// Compare against the Node baseline (bench/js/heartbeat-bench.mjs).
//
// Usage:
//   swift run --package-path bench/swift QVACBench [iterations]
//
// Output: JSON with min/p50/p99/max latencies in milliseconds.

import Foundation
import QVACClient

@main
struct QVACBench {
    static func main() async throws {
        let iterations = CommandLine.arguments.count > 1
            ? Int(CommandLine.arguments[1]) ?? 1000
            : 1000

        let nodeModulesDir = ProcessInfo.processInfo.environment["QVAC_NODE_MODULES"]
            ?? "/Users/hardik/Projects/qvac-swift/spike-js/node_modules"

        let cfg = try QVACClient.Configuration.macOS(
            nodeModulesDir: URL(fileURLWithPath: nodeModulesDir),
            initTimeout: 30.0
        )
        let client = try await QVACClient(configuration: cfg)
        defer { Task { await client.close() } }

        // Warm up — first call includes the worker init handshake.
        _ = try await client.heartbeat()

        var samples: [TimeInterval] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = Date()
            _ = try await client.heartbeat()
            samples.append(Date().timeIntervalSince(start) * 1000.0)
        }

        await client.close()

        let sorted = samples.sorted()
        let min = sorted.first ?? 0
        let max = sorted.last ?? 0
        let mean = samples.reduce(0, +) / Double(samples.count)
        let p50 = sorted[sorted.count / 2]
        let p99 = sorted[Int(Double(sorted.count) * 0.99)]

        let result: [String: Any] = [
            "client": "swift",
            "iterations": iterations,
            "min_ms": min,
            "mean_ms": mean,
            "p50_ms": p50,
            "p99_ms": p99,
            "max_ms": max,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
