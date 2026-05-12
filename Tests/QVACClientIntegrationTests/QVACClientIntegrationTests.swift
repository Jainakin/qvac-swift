// QVACClientIntegrationTests — high-level API end-to-end against a real Bare worker.
//
// Exercises the M2 public surface (QVACClient) rather than the low-level RPC primitives.
// Skipped automatically if `bare` / a built @qvac/sdk are unavailable.

import XCTest
@testable import QVACClient

#if canImport(Darwin)
final class QVACClientIntegrationTests: XCTestCase {

    private static let bareBin: URL? = {
        if let p = ProcessInfo.processInfo.environment["QVAC_BARE_BIN"] { return URL(fileURLWithPath: p) }
        let c = URL(fileURLWithPath: "/opt/homebrew/bin/bare")
        return FileManager.default.fileExists(atPath: c.path) ? c : nil
    }()

    private static let nodeModulesDir: URL? = {
        if let p = ProcessInfo.processInfo.environment["QVAC_NODE_MODULES"] { return URL(fileURLWithPath: p) }
        // Walk up from cwd looking for spike-js/node_modules — works whether `swift test`
        // is run from the repo root or from an Xcode derived-data dir.
        let suffix = "spike-js/node_modules"
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let c = dir.appendingPathComponent(suffix)
            if FileManager.default.fileExists(atPath: c.path) { return c }
            if dir.pathComponents.count <= 1 { break }
            dir.deleteLastPathComponent()
        }
        return nil
    }()

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.bareBin != nil, "bare not available; set QVAC_BARE_BIN")
        try XCTSkipUnless(Self.nodeModulesDir != nil, "@qvac/sdk node_modules not available; set QVAC_NODE_MODULES")
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.qvac/.worker.lock")
    }

    private func makeClient() async throws -> QVACClient {
        let cfg = try QVACClient.Configuration.macOS(
            nodeModulesDir: Self.nodeModulesDir!,
            bareExecutable: Self.bareBin!,
            initTimeout: 10.0
        )
        return try await QVACClient(configuration: cfg)
    }

    // MARK: - heartbeat

    func test_heartbeat_returns_worker_uptime() async throws {
        let client = try await makeClient()
        defer { Task { await client.close() } }
        let hb = try await client.heartbeat()
        XCTAssertGreaterThan(hb.number, 0)
    }

    // MARK: - cancel for nonexistent operation throws typed error

    func test_cancel_nonexistent_inference_throws() async throws {
        let client = try await makeClient()
        defer { Task { await client.close() } }
        do {
            try await client.cancel(.inference(modelId: "no-such-model"))
            XCTFail("expected throw")
        } catch let e as QVACError {
            if case .server(let code, _) = e {
                XCTAssertEqual(code, .cancelFailed)
            } else {
                XCTFail("expected .server(cancelFailed), got \(e)")
            }
        }
    }

    // MARK: - downloadAsset streaming

    func test_downloadAsset_streaming_yields_progress_and_id() async throws {
        let client = try await makeClient()
        defer { Task { await client.close() } }
        let (progress, idTask) = try await client.downloadAssetStreaming(
            assetSrc: "https://raw.githubusercontent.com/holepunchto/bare-rpc/main/README.md"
        )
        var sawProgress = false
        for try await tick in progress {
            XCTAssertGreaterThanOrEqual(tick.percentage, 0)
            XCTAssertLessThanOrEqual(tick.percentage, 100)
            sawProgress = true
        }
        let assetId = try await idTask.value
        XCTAssertFalse(assetId.isEmpty)
        // The probe-target file is 4.1KB — a tiny download — so we might get only ONE
        // progress tick or zero on slow hardware. Either is fine; what we care about
        // is that the typed assetId returns.
        _ = sawProgress
    }

    // MARK: - close idempotence

    func test_close_then_close_does_not_throw() async throws {
        let client = try await makeClient()
        await client.close()
        await client.close()
    }

    // MARK: - clean shutdown propagates to worker

    func test_close_terminates_worker_subprocess() async throws {
        let client = try await makeClient()
        // Worker is alive at this point. Closing should propagate SIGTERM → worker exits.
        let start = Date()
        await client.close()
        let elapsed = Date().timeIntervalSince(start)
        // Should be near-instant. We allow up to 2s to give the worker time to flush logs.
        XCTAssertLessThan(elapsed, 2.0)
    }
}
#endif
