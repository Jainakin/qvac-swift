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

    private static let resultPath: String = {
        ProcessInfo.processInfo.environment["QVAC_BENCH_RESULT"]
            ?? FileManager.default.currentDirectoryPath + "/bench/swift-result.json"
    }()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QVAC_RUN_BENCH"] == "1",
                          "set QVAC_RUN_BENCH=1 to run the heartbeat benchmark")
        try XCTSkipUnless(Self.bareBin != nil,        "set QVAC_BARE_BIN")
        try XCTSkipUnless(Self.nodeModulesDir != nil, "set QVAC_NODE_MODULES")
    }

    func test_heartbeat_latency_swift_baseline() async throws {
        let iters = Self.iterations
        let cfg = UDSTransportConfiguration(
            bareExecutable: Self.bareBin!,
            workerScript: Self.nodeModulesDir!
                .appendingPathComponent("@qvac/sdk/dist/server/worker.js"),
            workingDirectory: Self.nodeModulesDir!.deletingLastPathComponent(),
            initTimeout: 30.0
        )
        let transport = try await UnixDomainSocketTransport.connect(cfg)
        let rpc = BareRPCClient(transport: transport)
        try await QVACHandshake.sendInitConfig(on: rpc)

        let hbBody = try JSONEncoder().encode(QVACRequest.heartbeat(HeartbeatRequest()))
        var cmd: UInt64 = 2

        // Warmup.
        _ = try await rpc.send(command: cmd, data: hbBody); cmd += 1

        var samples: [TimeInterval] = []
        samples.reserveCapacity(iters)
        for _ in 0..<iters {
            let start = Date()
            _ = try await rpc.send(command: cmd, data: hbBody); cmd += 1
            samples.append(Date().timeIntervalSince(start) * 1000.0)
        }
        await rpc.close()

        let sorted = samples.sorted()
        let result: [String: Any] = [
            "client": "swift",
            "iterations": iters,
            "min_ms":  sorted.first ?? 0,
            "mean_ms": samples.reduce(0, +) / Double(samples.count),
            "p50_ms":  sorted[sorted.count / 2],
            "p99_ms":  sorted[Int(Double(sorted.count) * 0.99)],
            "max_ms":  sorted.last ?? 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: Self.resultPath))
        let summary = String(data: data, encoding: .utf8) ?? ""
        // Print to stdout so the bench harness can scrape it too.
        print("[bench-swift] \(summary)")
    }
}

#endif
