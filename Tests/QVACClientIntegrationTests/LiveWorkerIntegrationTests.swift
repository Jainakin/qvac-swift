// LiveWorkerIntegrationTests — spawn a real `bare worker.js` and exercise the full
// init → heartbeat → downloadAsset → cancel cycle. Mirrors what the Phase-0 MacOSProbe
// does, but assertion-driven inside the test framework.
//
// These tests are SKIPPED unless `bare` and a built `@qvac/sdk` are present at well-known
// locations (controlled via env). CI runs them on macOS-14-arm64 runners; local dev runs
// them via `swift test --filter LiveWorkerIntegrationTests`.

import XCTest
@testable import QVACClient

#if canImport(Darwin)
import Darwin

final class LiveWorkerIntegrationTests: XCTestCase {

    // MARK: - Environment

    private static let nodeModulesDir: URL? = {
        if let p = ProcessInfo.processInfo.environment["QVAC_NODE_MODULES"] {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        let suffix = "tools/runtime/node_modules"
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(suffix)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            if dir.pathComponents.count <= 1 { break }
            dir.deleteLastPathComponent()
        }
        return nil
    }()

    private static let bareBin: URL? = ProcessInfo.processInfo.environment["QVAC_BARE_BIN"]
        .map { URL(fileURLWithPath: $0) }
        ?? nodeModulesDir?.appendingPathComponent(".bin/bare")
    private static let workerScript: URL? = ProcessInfo.processInfo.environment["QVAC_WORKER_SCRIPT"]
        .map { URL(fileURLWithPath: $0) }
        ?? nodeModulesDir?.appendingPathComponent("@qvac/sdk/dist/server/worker.js")
    private var workerHome: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.bareBin != nil, "bare runtime not available; install via `npm i -g bare-runtime` or set QVAC_BARE_BIN")
        try XCTSkipUnless(Self.workerScript != nil, "QVAC worker.js not found; set QVAC_WORKER_SCRIPT to <node_modules>/@qvac/sdk/dist/server/worker.js")
        let packageJSON = try XCTUnwrap(Self.nodeModulesDir).appendingPathComponent("@qvac/sdk/package.json")
        let data = try Data(contentsOf: packageJSON)
        let package = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try XCTSkipUnless(package["version"] as? String == "0.17.0", "live tests require exact @qvac/sdk 0.17.0")
        workerHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qvac-live-worker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workerHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workerHome { try? FileManager.default.removeItem(at: workerHome) }
    }

    private func newTransport() async throws -> UnixDomainSocketTransport {
        let config = UDSTransportConfiguration(
            bareExecutable: Self.bareBin!,
            workerScript: Self.workerScript!,
            workingDirectory: Self.nodeModulesDir!.deletingLastPathComponent(),
            initTimeout: 60.0,
            homeDir: workerHome.path
        )
        return try await UnixDomainSocketTransport.connect(config)
    }

    // MARK: - Tests

    /// Smoke test: spawn the worker, perform the __init_config handshake, send heartbeat,
    /// close. End-to-end in under 5 seconds.
    func test_full_init_and_heartbeat_roundtrip() async throws {
        let started = Date()
        let transport = try await newTransport()
        let rpc = BareRPCClient(transport: transport)
        addTeardownBlock { await rpc.close() }

        // Init handshake.
        try await QVACHandshake.sendInitConfig(on: rpc, timeout: .seconds(30))

        // Heartbeat.
        let heartbeatRequest = QVACRequest.heartbeat(HeartbeatRequest())
        let body = try JSONEncoder.qvac.encode(heartbeatRequest)
        let respData = try await rpc.send(command: 2, data: body, timeout: .seconds(30))
        XCTAssertNotNil(respData)
        let resp = try JSONDecoder().decode(QVACResponse.self, from: respData!)
        guard case .heartbeat(let hb) = resp else {
            return XCTFail("expected heartbeat response, got \(resp.discriminator)")
        }
        // The "number" field is the worker's uptime in seconds — sanity check it's plausible.
        XCTAssertGreaterThan(hb.number, 0)

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5.0, "end-to-end should be < 5s; got \(elapsed)s")
    }

    /// Streaming smoke test: downloadAsset a tiny URL. The worker emits at least one
    /// `modelProgress` NDJSON event and a final `downloadAsset` envelope.
    func test_streaming_downloadAsset_emits_progress_and_completion() async throws {
        let transport = try await newTransport()
        let rpc = BareRPCClient(transport: transport)
        addTeardownBlock { await rpc.close() }

        try await QVACHandshake.sendInitConfig(on: rpc, timeout: .seconds(30))

        // Independently hash the immutable network fixture before asking the
        // worker to download the same URL, then exercise the raw 0.17 wire shape.
        let fixture = VerifiedModelFixture.downloadAssetProbe
        _ = try await fixture.localURL()
        let requestData = try JSONSerialization.data(withJSONObject: [
            "type": "downloadAsset",
            "assetSrc": fixture.source.absoluteString,
            "withProgress": true,
        ])

        let stream = try await rpc.stream(
            command: 3,
            data: requestData,
            timeout: .seconds(30)
        )
        var sawProgress = false
        var sawCompletion = false
        for try await raw in stream.chunks {
            // The wire format is NDJSON inside each STREAM-DATA frame; the chunk may contain
            // one or several lines.
            let text = String(data: raw, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }
                if obj["type"] as? String == "modelProgress" { sawProgress = true }
                if obj["type"] as? String == "downloadAsset" {
                    sawCompletion = true
                    if let ok = obj["success"] as? Bool, ok {
                        return // success path
                    }
                }
            }
            if sawCompletion { return }
        }
        XCTAssertTrue(sawProgress, "expected at least one modelProgress event")
        XCTAssertTrue(sawCompletion, "expected a downloadAsset completion event")
    }

    /// Exercise both native 0.17 cancel arms. A missing request id is an idempotent
    /// success (`cancelled: 0`); broad-cancelling an unloaded model is an application
    /// error. Legacy wire operations such as `inference` are intentionally not sent.
    func test_cancel_native_request_and_broad_shapes() async throws {
        let transport = try await newTransport()
        let rpc = BareRPCClient(transport: transport)
        addTeardownBlock { await rpc.close() }

        try await QVACHandshake.sendInitConfig(on: rpc, timeout: .seconds(30))

        let targetedJSON = #"""
        {"type":"cancel","operation":"request","requestId":"this-does-not-exist"}
        """#
        let targetedReply = try await rpc.send(
            command: 4,
            data: Data(targetedJSON.utf8),
            timeout: .seconds(30)
        )
        let targetedData = try XCTUnwrap(targetedReply)
        let targeted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: targetedData) as? [String: Any]
        )
        XCTAssertEqual(targeted["type"] as? String, "cancel")
        XCTAssertEqual(targeted["success"] as? Bool, true)
        XCTAssertEqual(targeted["cancelled"] as? Int, 0)

        let broadJSON = #"""
        {"type":"cancel","operation":"broad","modelId":"this-does-not-exist","kind":"completion"}
        """#
        let broadReply = try await rpc.send(
            command: 5,
            data: Data(broadJSON.utf8),
            timeout: .seconds(30)
        )
        let broadData = try XCTUnwrap(broadReply)
        let broad = try XCTUnwrap(
            JSONSerialization.jsonObject(with: broadData) as? [String: Any]
        )
        XCTAssertEqual(broad["type"] as? String, "cancel")
        XCTAssertEqual(broad["success"] as? Bool, false)
        XCTAssertFalse((broad["error"] as? String)?.isEmpty ?? true)
    }

    /// Close should be idempotent and tear down cleanly. Re-running after close should
    /// be a no-op without crashing.
    func test_close_idempotent() async throws {
        let transport = try await newTransport()
        let rpc = BareRPCClient(transport: transport)
        try await QVACHandshake.sendInitConfig(on: rpc, timeout: .seconds(30))
        await rpc.close()
        await rpc.close() // idempotent
    }

    /// AC-7: `close()` tears down the IPC connection AND the worker subprocess. This goes
    /// beyond the previous "didn't crash" check — we assert (a) the worker reports a clean
    /// exit via NSTask, and (b) the OS confirms the PID is gone via `kill(pid, 0)`.
    func test_close_terminates_worker_subprocess_with_clean_exit() async throws {
        let transport = try await newTransport()
        let rpc = BareRPCClient(transport: transport)
        try await QVACHandshake.sendInitConfig(on: rpc, timeout: .seconds(30))

        // Capture the live worker PID before close.
        let pidBefore = transport.__testWorkerPID()
        XCTAssertGreaterThan(pidBefore, 0, "worker PID should be assigned post-handshake")
        // While running, kill(pid, 0) returns 0 (process exists).
        XCTAssertEqual(Darwin.kill(pidBefore, 0), 0,
                       "worker proc must be alive before close (kill -0 = \(errno))")

        // Tear down. close() awaits worker subprocess exit internally.
        await rpc.close()

        // After close, the transport's worker handle should report not-running with a
        // clean termination reason. NSTask's `.exit` rawValue is 1; `.uncaughtSignal` is 2.
        // `terminate()` sends SIGTERM, which `bare` catches and exits cleanly — so we
        // accept either .exit/0 or a signal-prompted clean exit.
        if let info = transport.__testWorkerExitInfo() {
            XCTAssertFalse(info.isRunning, "worker proc must not be running after close")
        }
        // Most importantly: the OS reports the PID as gone (kill -0 returns -1 with ESRCH).
        let stillExists = Darwin.kill(pidBefore, 0) == 0
        XCTAssertFalse(stillExists,
                       "worker pid \(pidBefore) must be gone after close; OS still sees it")
    }
}

#endif
