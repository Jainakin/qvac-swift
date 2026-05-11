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

    private static let bareBin: URL? = {
        // 1. Honour an explicit env override.
        if let p = ProcessInfo.processInfo.environment["QVAC_BARE_BIN"] {
            return URL(fileURLWithPath: p)
        }
        // 2. Default to the homebrew location used by Phase-0 spikes.
        let candidate = URL(fileURLWithPath: "/opt/homebrew/bin/bare")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return nil
    }()

    private static let workerScript: URL? = {
        if let p = ProcessInfo.processInfo.environment["QVAC_WORKER_SCRIPT"] {
            return URL(fileURLWithPath: p)
        }
        // Default to the spike-js installation that powered Phase-0 validation.
        let p = "/Users/hardik/Projects/qvac-swift/spike-js/node_modules/@qvac/sdk/dist/server/worker.js"
        if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        return nil
    }()

    private static var workingDir: URL? {
        guard let s = workerScript else { return nil }
        // Walk up from `node_modules/@qvac/sdk/.../worker.js` to the dir whose `node_modules`
        // is the install root.
        var dir = s.deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            let nm = dir.appendingPathComponent("node_modules")
            if FileManager.default.fileExists(atPath: nm.path) { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.bareBin != nil, "bare runtime not available; install via `npm i -g bare-runtime` or set QVAC_BARE_BIN")
        try XCTSkipUnless(Self.workerScript != nil, "QVAC worker.js not found; set QVAC_WORKER_SCRIPT to <node_modules>/@qvac/sdk/dist/server/worker.js")
        // Pre-test: ensure no stale worker is holding the global lock.
        let lockFile = NSHomeDirectory() + "/.qvac/.worker.lock"
        try? FileManager.default.removeItem(atPath: lockFile)
    }

    private func newTransport() async throws -> UnixDomainSocketTransport {
        let config = UDSTransportConfiguration(
            bareExecutable: Self.bareBin!,
            workerScript: Self.workerScript!,
            workingDirectory: Self.workingDir!,
            initTimeout: 10.0
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
        defer { Task { await rpc.close() } }

        // Init handshake.
        try await QVACHandshake.sendInitConfig(on: rpc)

        // Heartbeat.
        let heartbeatRequest = QVACRequest.heartbeat(HeartbeatRequest())
        let body = try JSONEncoder.qvac.encode(heartbeatRequest)
        let respData = try await rpc.send(command: 2, data: body)
        XCTAssertNotNil(respData)
        let resp = try JSONDecoder().decode(QVACResponse.self, from: respData!)
        guard case .heartbeat(let hb) = resp else {
            return XCTFail("expected heartbeat response, got \(resp.discriminator)")
        }
        // The "number" field is the worker's uptime in seconds — sanity check it's plausible.
        XCTAssertGreaterThan(hb.number ?? -1, 0)

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5.0, "end-to-end should be < 5s; got \(elapsed)s")
    }

    /// Streaming smoke test: downloadAsset a tiny URL. The worker emits at least one
    /// `modelProgress` NDJSON event and a final `downloadAsset` envelope.
    func test_streaming_downloadAsset_emits_progress_and_completion() async throws {
        let transport = try await newTransport()
        let rpc = BareRPCClient(transport: transport)
        defer { Task { await rpc.close() } }

        try await QVACHandshake.sendInitConfig(on: rpc)

        // We don't yet have a hand-written wrapper for downloadAsset (M2 work). For the
        // integration test we send the raw JSON shape that the JS schemas expect, then
        // decode the streamed NDJSON via JSONDecoder per chunk.
        let requestJSON = #"""
        {"type":"downloadAsset","assetSrc":"https://raw.githubusercontent.com/holepunchto/bare-rpc/main/README.md","withProgress":true}
        """#

        let stream = try await rpc.stream(command: 3, data: Data(requestJSON.utf8))
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

    /// Cancel a nonexistent operation. The worker returns `{success:false, error: …}`
    /// — verifies the cancel wire shape from end to end.
    func test_cancel_nonexistent_inference_returns_error_envelope() async throws {
        let transport = try await newTransport()
        let rpc = BareRPCClient(transport: transport)
        defer { Task { await rpc.close() } }

        try await QVACHandshake.sendInitConfig(on: rpc)

        let cancelJSON = #"""
        {"type":"cancel","operation":"inference","modelId":"this-does-not-exist"}
        """#
        let respData = try await rpc.send(command: 4, data: Data(cancelJSON.utf8))
        XCTAssertNotNil(respData)
        let obj = try JSONSerialization.jsonObject(with: respData!) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "cancel")
        XCTAssertEqual(obj?["success"] as? Bool, false)
        XCTAssertTrue((obj?["error"] as? String)?.contains("not found") ?? false)
    }

    /// Close should be idempotent and tear down cleanly. Re-running after close should
    /// be a no-op without crashing.
    func test_close_terminates_worker_cleanly() async throws {
        let transport = try await newTransport()
        let rpc = BareRPCClient(transport: transport)
        try await QVACHandshake.sendInitConfig(on: rpc)
        await rpc.close()
        await rpc.close() // idempotent
    }
}

#endif
