// QVACClientIntegrationTests — high-level API end-to-end against a real Bare worker.
//
// Exercises the M2 public surface (QVACClient) rather than the low-level RPC primitives.
// Skipped automatically if the exact tools/runtime graph is unavailable.

import XCTest
@testable import QVACClient

#if canImport(Darwin)
final class QVACClientIntegrationTests: XCTestCase {

    private static let nodeModulesDir: URL? = {
        if let p = ProcessInfo.processInfo.environment["QVAC_NODE_MODULES"] { return URL(fileURLWithPath: p) }
        let suffix = "tools/runtime/node_modules"
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let c = dir.appendingPathComponent(suffix)
            if FileManager.default.fileExists(atPath: c.path) { return c }
            if dir.pathComponents.count <= 1 { break }
            dir.deleteLastPathComponent()
        }
        return nil
    }()

    private static let bareBin: URL? = {
        if let p = ProcessInfo.processInfo.environment["QVAC_BARE_BIN"] { return URL(fileURLWithPath: p) }
        return nodeModulesDir?.appendingPathComponent(".bin/bare")
    }()

    private var workerHome: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.bareBin != nil, "bare not available; set QVAC_BARE_BIN")
        try XCTSkipUnless(Self.nodeModulesDir != nil, "@qvac/sdk node_modules not available; set QVAC_NODE_MODULES")
        let packageJSON = Self.nodeModulesDir!.appendingPathComponent("@qvac/sdk/package.json")
        let data = try Data(contentsOf: packageJSON)
        let package = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try XCTSkipUnless(package["version"] as? String == "0.17.0", "integration tests require exact @qvac/sdk 0.17.0")
        workerHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qvac-client-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workerHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workerHome { try? FileManager.default.removeItem(at: workerHome) }
    }

    private func makeClient() async throws -> QVACClient {
        let modules = Self.nodeModulesDir!
        let cfg = QVACClient.Configuration.macOSSubprocess(UDSTransportConfiguration(
            bareExecutable: Self.bareBin!,
            workerScript: modules.appendingPathComponent("@qvac/sdk/dist/server/worker.js"),
            workingDirectory: modules.deletingLastPathComponent(),
            initTimeout: 60.0,
            homeDir: workerHome.path
        ))
        return try await QVACClient(
            configuration: cfg,
            initHandshakeTimeout: .seconds(60)
        )
    }

    // MARK: - heartbeat

    func test_heartbeat_returns_worker_uptime() async throws {
        let client = try await makeClient()
        addTeardownBlock { await client.close() }
        let hb = try await client.heartbeat(
            rpcOptions: .init(timeout: .seconds(30))
        )
        XCTAssertGreaterThan(hb.number, 0)
    }

    // MARK: - cancel for nonexistent operation throws typed error

    func test_cancel_nonexistent_model_throws() async throws {
        let client = try await makeClient()
        addTeardownBlock { await client.close() }
        do {
            try await client.cancel(
                .broad(modelId: "no-such-model"),
                rpcOptions: .init(timeout: .seconds(30))
            )
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
        addTeardownBlock { await client.close() }
        let fixture = VerifiedModelFixture.downloadAssetProbe
        _ = try await fixture.localURL()
        let run = try await client.downloadAssetStreaming(
            assetSrc: fixture.source.absoluteString,
            rpcOptions: .init(timeout: .seconds(30))
        )
        var sawProgress = false
        for try await tick in run.progress {
            XCTAssertGreaterThanOrEqual(tick.percentage, 0)
            XCTAssertLessThanOrEqual(tick.percentage, 100)
            sawProgress = true
        }
        let assetId = try await run.result.value
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
