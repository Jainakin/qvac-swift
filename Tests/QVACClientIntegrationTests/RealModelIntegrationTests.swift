// RealModelIntegrationTests — download + load a small LLM, run streaming completion,
// cancel mid-stream, unload, and verify graceful shutdown.
//
// These tests download an immutable, public 105,454,432-byte GGUF and verify its
// SHA-256 before the worker sees it.
// They are GATED on the `QVAC_RUN_REAL_MODEL_TESTS=1` environment variable so default CI
// runs stay fast. Locally:
//
//     QVAC_RUN_REAL_MODEL_TESTS=1 swift test --filter RealModelIntegrationTests
//
// A custom QVAC_TEST_MODEL_URL requires QVAC_TEST_MODEL_SHA256 and
// QVAC_TEST_MODEL_SIZE. Public pinned defaults never require HF_TOKEN.

import XCTest
@testable import QVACClient

#if canImport(Darwin)
final class RealModelIntegrationTests: XCTestCase {

    private static let bareBin: URL? = {
        if let p = ProcessInfo.processInfo.environment["QVAC_BARE_BIN"] { return URL(fileURLWithPath: p) }
        let c = URL(fileURLWithPath: "/opt/homebrew/bin/bare")
        return FileManager.default.fileExists(atPath: c.path) ? c : nil
    }()

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

    private static let modelType: String = {
        ProcessInfo.processInfo.environment["QVAC_TEST_MODEL_TYPE"] ?? "llamacpp-completion"
    }()

    private var workerHome: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QVAC_RUN_REAL_MODEL_TESTS"] == "1",
                          "set QVAC_RUN_REAL_MODEL_TESTS=1 to opt into model-download tests")
        guard let bare = Self.bareBin, FileManager.default.isExecutableFile(atPath: bare.path) else {
            throw IntegrationPrerequisiteError("QVAC_RUN_REAL_MODEL_TESTS=1 but QVAC_BARE_BIN is missing or not executable")
        }
        guard let modules = Self.nodeModulesDir, FileManager.default.fileExists(atPath: modules.path) else {
            throw IntegrationPrerequisiteError("QVAC_RUN_REAL_MODEL_TESTS=1 but QVAC_NODE_MODULES is missing")
        }
        try Self.requireSDK017(in: modules)
        _ = try Self.fixture()
        workerHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qvac-real-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workerHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workerHome { try? FileManager.default.removeItem(at: workerHome) }
    }

    private static func fixture() throws -> VerifiedModelFixture {
        try VerifiedModelFixture.fromEnvironment(
            default: .realModelDefault,
            urlKey: "QVAC_TEST_MODEL_URL",
            sha256Key: "QVAC_TEST_MODEL_SHA256",
            sizeKey: "QVAC_TEST_MODEL_SIZE"
        )
    }

    private static func requireSDK017(in modules: URL) throws {
        let packageJSON = modules.appendingPathComponent("@qvac/sdk/package.json")
        guard let data = try? Data(contentsOf: packageJSON),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? String == "0.17.0" else {
            throw IntegrationPrerequisiteError("QVAC_NODE_MODULES must contain exact @qvac/sdk 0.17.0 (run npm ci --prefix tools/runtime)")
        }
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

    private func loadFixtureModel(
        on client: QVACClient,
        from modelURL: URL
    ) async throws -> String {
        let load = try await client.loadModelStreaming(
            modelSrc: modelURL.path,
            modelType: Self.modelType,
            rpcOptions: .init(timeout: .seconds(600))
        )
        let progressConsumer = Task<Void, Error> {
            for try await tick in load.progress {
                print(
                    "[load-progress] downloaded=\(Int(tick.downloaded)) "
                    + "total=\(Int(tick.total)) "
                    + "pct=\(String(format: "%.1f", tick.percentage))%"
                )
            }
        }
        do {
            let modelId = try await load.result.value
            try await progressConsumer.value
            return modelId
        } catch let operationError {
            progressConsumer.cancel()
            do {
                try await progressConsumer.value
            } catch is CancellationError {
                // Expected when the result fails before the progress stream settles.
            } catch {
                XCTFail("load progress consumer cleanup failed: \(error)")
            }
            throw operationError
        }
    }

    private func waitForNoInFlightWork(
        on client: QVACClient,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let rpc = await client.rpc
        while clock.now < deadline {
            if await rpc.__testInFlightCounts() == (0, 0, 0) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        let counts = await rpc.__testInFlightCounts()
        XCTFail("completion cancellation left in-flight RPC state: \(counts)")
    }

    // QVAC-219: full load → stream → unload cycle.
    func test_load_completion_stream_unload() async throws {
        let client = try await makeClient()
        addTeardownBlock { await client.close() }
        let modelURL = try await Self.fixture().localURL()

        // Load with progress events for visibility into download.
        let modelId = try await loadFixtureModel(on: client, from: modelURL)
        XCTAssertFalse(modelId.isEmpty)
        do {
            // Streaming completion.
            let run = try await client.completion(
                modelId: modelId,
                history: [.user("Say hello in one word.")],
                generationParams: .object(["predict": .number(8)]),
                rpcOptions: .init(timeout: .seconds(60))
            )
            var tokensSeen = 0
            var fullText = ""
            for try await tok in run.tokenStream {
                fullText += tok
                tokensSeen += 1
                if tokensSeen >= 16 { break }
            }
            _ = try await run.final.value
            XCTAssertGreaterThan(tokensSeen, 0)
            XCTAssertFalse(fullText.isEmpty)

            // Unload is part of the asserted success path, not fire-and-forget
            // teardown that could leave the worker alive after XCTest returns.
            try await client.unloadModel(
                modelId: modelId,
                rpcOptions: .init(timeout: .seconds(10))
            )
        } catch let operationError {
            do {
                try await client.unloadModel(
                    modelId: modelId,
                    rpcOptions: .init(timeout: .seconds(10))
                )
            } catch {
                XCTFail("completion failure cleanup could not unload model: \(error)")
            }
            throw operationError
        }
    }

    // QVAC-220: cancel a long-running completion mid-stream.
    func test_cancel_aborts_in_flight_completion() async throws {
        let client = try await makeClient()
        addTeardownBlock { await client.close() }
        let modelURL = try await Self.fixture().localURL()

        let modelId = try await loadFixtureModel(on: client, from: modelURL)
        do {
            // Cancel as soon as the client exposes the request id. QVAC 0.17
            // deliberately records a targeted cancel that reaches the worker
            // before request registration, then applies it when begin arrives.
            // Waiting for a token makes this test racy with very small/fast models:
            // the worker can emit its terminal event before the cancel RPC wins.
            let run = try await client.completion(
                modelId: modelId,
                history: [.user(
                    "Write the integers from 1 through 10000, one per line. "
                    + "Do not summarize, skip values, or stop early."
                )],
                generationParams: .object(["predict": .number(4096)]),
                rpcOptions: .init(timeout: .seconds(30))
            )

            let eventConsumer = Task<[QVACClient.CompletionEvent], Error> {
                var events: [QVACClient.CompletionEvent] = []
                for try await event in run.events { events.append(event) }
                return events
            }

            let clock = ContinuousClock()
            let start = clock.now
            let acknowledgement = try await client.cancel(
                .request(requestId: run.requestId),
                rpcOptions: .init(timeout: .seconds(2))
            )
            let cancelled = try XCTUnwrap(
                acknowledgement.cancelled,
                "QVAC 0.17 cancel acknowledgements always carry a registry count"
            )
            XCTAssertTrue(
                cancelled == 0 || cancelled == 1,
                "targeted cancel must affect at most one request; zero means the cancel-before-begin guard recorded it"
            )

            do {
                _ = try await run.final.value
                XCTFail("cancelled completion final must reject")
            } catch let error as QVACError {
                guard case .inferenceCancelled(let requestId, let partial) = error else {
                    throw error
                }
                XCTAssertEqual(requestId, run.requestId)
                XCTAssertNotNil(partial.text)
                XCTAssertNotNil(partial.toolCalls)
            }
            let events = try await eventConsumer.value
            XCTAssertTrue(events.contains { event in
                guard case .done(_, let stopReason, _) = event else { return false }
                return stopReason == .cancelled
            }, "event stream must end normally with completionDone(cancelled)")

            XCTAssertLessThan(
                start.duration(to: clock.now),
                .seconds(5),
                "completion should terminate within 5s of cancel"
            )
            try await waitForNoInFlightWork(on: client)
            try await client.unloadModel(
                modelId: modelId,
                rpcOptions: .init(timeout: .seconds(10))
            )
        } catch let operationError {
            do {
                try await client.unloadModel(
                    modelId: modelId,
                    rpcOptions: .init(timeout: .seconds(10))
                )
            } catch {
                XCTFail("cancellation failure cleanup could not unload model: \(error)")
            }
            throw operationError
        }
    }

    // QVAC-221: graceful shutdown — close() while no operations are pending.
    func test_close_after_idle_terminates_worker() async throws {
        let client = try await makeClient()
        addTeardownBlock { await client.close() }
        // Idle the client (just a heartbeat).
        _ = try await client.heartbeat(rpcOptions: .init(timeout: .seconds(10)))
        let clock = ContinuousClock()
        let start = clock.now
        await client.close()
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
    }
}
#endif
