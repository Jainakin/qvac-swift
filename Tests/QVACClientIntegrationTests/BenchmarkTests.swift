// BenchmarkTests — runs the Swift-side KR-2 latency measurement as an XCTestCase.
//
// AUDIT §3. Lives alongside the integration tests because it needs a live worker.
// The bench/run.sh script wraps `swift test` to do the Swift+Node side-by-side
// comparison; this file is just the Swift half.
//
// Gated on QVAC_RUN_BENCH=1 so it doesn't run by default in `swift test`.

import XCTest
@testable import QVACClient

#if canImport(Darwin)
import Darwin

final class BenchmarkTests: XCTestCase {

    private static let bareBin: URL? = {
        if let p = ProcessInfo.processInfo.environment["QVAC_BARE_BIN"] {
            return URL(fileURLWithPath: p)
        }
        let p = "/opt/homebrew/bin/bare"
        return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
    }()

    private static let nodeModulesDir: URL? = {
        if let p = ProcessInfo.processInfo.environment["QVAC_NODE_MODULES"] {
            return URL(fileURLWithPath: p)
        }
        return nil
    }()

    private static let iterations: Int = {
        Int(ProcessInfo.processInfo.environment["QVAC_BENCH_ITERS"] ?? "") ?? 200
    }()

    private static let warmupIterations: Int = {
        Int(ProcessInfo.processInfo.environment["QVAC_BENCH_WARMUP"] ?? "") ?? 50
    }()

    private static let resultPath: String = {
        ProcessInfo.processInfo.environment["QVAC_BENCH_RESULT"]
            ?? FileManager.default.currentDirectoryPath + "/bench/swift-result.json"
    }()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QVAC_RUN_BENCH"] == "1",
                          "set QVAC_RUN_BENCH=1 to run the heartbeat benchmark")
        guard let bare = Self.bareBin, FileManager.default.isExecutableFile(atPath: bare.path) else {
            throw IntegrationPrerequisiteError("QVAC_RUN_BENCH=1 but QVAC_BARE_BIN is missing or not executable")
        }
        guard let modules = Self.nodeModulesDir else {
            throw IntegrationPrerequisiteError("QVAC_RUN_BENCH=1 but QVAC_NODE_MODULES is missing")
        }
        let packageJSON = modules.appendingPathComponent("@qvac/sdk/package.json")
        guard let data = try? Data(contentsOf: packageJSON),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? String == "0.17.0" else {
            throw IntegrationPrerequisiteError("benchmark requires exact @qvac/sdk 0.17.0 from tools/runtime/package-lock.json")
        }
        guard Self.iterations >= 100, Self.warmupIterations > 0 else {
            throw IntegrationPrerequisiteError("benchmark requires >=100 samples and at least one warmup")
        }
    }

    func test_heartbeat_latency_swift_baseline() async throws {
        let iters = Self.iterations
        let cfg = UDSTransportConfiguration(
            bareExecutable: Self.bareBin!,
            workerScript: Self.nodeModulesDir!
                .appendingPathComponent("@qvac/sdk/dist/server/worker.js"),
            workingDirectory: Self.nodeModulesDir!.deletingLastPathComponent(),
            initTimeout: 30.0,
            homeDir: ProcessInfo.processInfo.environment["QVAC_BENCH_HOME"]
        )
        let client = try await QVACClient(
            configuration: .macOSSubprocess(cfg),
            initHandshakeTimeout: .seconds(30),
            logger: nil
        )
        let clock = ContinuousClock()
        var samples: [Double] = []
        do {
            for _ in 0..<Self.warmupIterations {
                _ = try await client.heartbeat()
            }

            samples.reserveCapacity(iters)
            for _ in 0..<iters {
                let start = clock.now
                _ = try await client.heartbeat()
                let duration = start.duration(to: clock.now).components
                samples.append(
                    Double(duration.seconds) * 1_000.0
                        + Double(duration.attoseconds) / 1_000_000_000_000_000.0
                )
            }
            await client.close()
        } catch {
            await client.close()
            throw error
        }
        guard samples.count == iters, samples.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw IntegrationPrerequisiteError("Swift public heartbeat benchmark produced invalid samples")
        }

        let sorted = samples.sorted()
        let result: [String: Any] = [
            "client": "swift",
            "iterations": iters,
            "warmup_iterations": Self.warmupIterations,
            "min_ms":  sorted.first ?? 0,
            "mean_ms": samples.reduce(0, +) / Double(samples.count),
            "p50_ms":  sorted[sorted.count / 2],
            "p99_ms":  sorted[Int(Double(sorted.count) * 0.99)],
            "max_ms":  sorted.last ?? 0,
            "samples_ms": samples,
            "api_surface": "QVACClient.heartbeat()",
            "timeout_policy": "outer-owned-process-watchdog-no-per-call-timeout",
            "toolchain": [
                "node": ProcessInfo.processInfo.environment["QVAC_BENCH_NODE_VERSION"] ?? "unknown",
                "bare": ProcessInfo.processInfo.environment["QVAC_BENCH_BARE_VERSION"] ?? "unknown",
                "swift": ProcessInfo.processInfo.environment["QVAC_BENCH_SWIFT_VERSION"] ?? "unknown",
                "host": ProcessInfo.processInfo.environment["QVAC_BENCH_HOST"] ?? "unknown",
                "watchdog_seconds": Int(
                    ProcessInfo.processInfo.environment["QVAC_BENCH_PROCESS_TIMEOUT_SECONDS"] ?? ""
                ) ?? -1,
                "sdk": "0.17.0",
                "configuration": "release",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: Self.resultPath))
        let summary = String(data: data, encoding: .utf8) ?? ""
        // Print to stdout so the bench harness can scrape it too.
        print("[bench-swift] \(summary)")
    }
}

#endif
