// RealModelIntegrationTests — download + load a small LLM, run streaming completion,
// cancel mid-stream, unload, and verify graceful shutdown.
//
// These tests require an actual model download (~50–700MB depending on `QVAC_TEST_MODEL_URL`).
// They are GATED on the `QVAC_RUN_REAL_MODEL_TESTS=1` environment variable so default CI
// runs stay fast. Locally:
//
//     QVAC_RUN_REAL_MODEL_TESTS=1 swift test --filter RealModelIntegrationTests
//
// Optional overrides:
//     QVAC_TEST_MODEL_URL  default = SmolLM-135M-Instruct-Q4_K_M.gguf (~91MB)
//     QVAC_TEST_MODEL_TYPE default = "llamacpp-completion"

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
        let p = "/Users/hardik/Projects/qvac-swift/spike-js/node_modules"
        return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
    }()

    private static let modelURL: String = {
        ProcessInfo.processInfo.environment["QVAC_TEST_MODEL_URL"]
            ?? "https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct-GGUF/resolve/main/smollm2-135m-instruct-q4_k_m.gguf"
    }()

    private static let modelType: String = {
        ProcessInfo.processInfo.environment["QVAC_TEST_MODEL_TYPE"] ?? "llamacpp-completion"
    }()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QVAC_RUN_REAL_MODEL_TESTS"] == "1",
                          "set QVAC_RUN_REAL_MODEL_TESTS=1 to opt into model-download tests")
        try XCTSkipUnless(Self.bareBin != nil)
        try XCTSkipUnless(Self.nodeModulesDir != nil)
        // Many HuggingFace endpoints now require authentication. Skip cleanly with a
        // pointer to the workaround if HF_TOKEN isn't in env and the test URL is HF.
        let url = Self.modelURL
        if url.contains("huggingface.co") && ProcessInfo.processInfo.environment["HF_TOKEN"] == nil {
            throw XCTSkip("HuggingFace model URL requires HF_TOKEN (export HF_TOKEN=<your-token>), or set QVAC_TEST_MODEL_URL to a public source")
        }
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.qvac/.worker.lock")
    }

    private func makeClient() async throws -> QVACClient {
        let cfg = try QVACClient.Configuration.macOS(
            nodeModulesDir: Self.nodeModulesDir!,
            bareExecutable: Self.bareBin!,
            initTimeout: 30.0
        )
        return try await QVACClient(configuration: cfg)
    }

    // QVAC-219: full load → stream → unload cycle.
    func test_load_completion_stream_unload() async throws {
        let client = try await makeClient()
        defer { Task { await client.close() } }

        // Load with progress events for visibility into download.
        let (progress, idTask) = try await client.loadModelStreaming(
            modelSrc: Self.modelURL,
            modelType: Self.modelType
        )
        Task.detached {
            for try await tick in progress {
                print("[load-progress] downloaded=\(Int(tick.downloaded)) total=\(Int(tick.total)) pct=\(String(format: "%.1f", tick.percentage))%")
            }
        }
        let modelId = try await idTask.value
        XCTAssertFalse(modelId.isEmpty)

        // Streaming completion.
        let run = try await client.completion(
            modelId: modelId,
            history: [.user("Say hello in one word.")],
            generationParams: .object(["max_new_tokens": .number(8)])
        )
        var tokensSeen = 0
        var fullText = ""
        for try await tok in run.tokenStream {
            fullText += tok
            tokensSeen += 1
            if tokensSeen >= 16 { break }
        }
        _ = try? await run.final.value
        XCTAssertGreaterThan(tokensSeen, 0)
        XCTAssertFalse(fullText.isEmpty)

        // Unload — should auto-close the connection.
        try await client.unloadModel(modelId: modelId)
    }

    // QVAC-220: cancel a long-running completion mid-stream.
    func test_cancel_aborts_in_flight_completion() async throws {
        let client = try await makeClient()
        defer { Task { await client.close() } }

        let (_, idTask) = try await client.loadModelStreaming(
            modelSrc: Self.modelURL,
            modelType: Self.modelType
        )
        let modelId = try await idTask.value

        // Start a completion that would normally yield many tokens.
        let run = try await client.completion(
            modelId: modelId,
            history: [.user("Tell me a long story.")],
            generationParams: .object(["max_new_tokens": .number(512)])
        )

        // Consume a few tokens, then cancel and assert the stream terminates promptly.
        let cancelTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)   // 200ms head-start
            try? await client.cancel(.inference(modelId: modelId))
        }

        let start = Date()
        var tokensSeen = 0
        for try await _ in run.tokenStream {
            tokensSeen += 1
            if tokensSeen > 500 { break }   // sanity bound
        }
        let elapsed = Date().timeIntervalSince(start)
        await cancelTask.value

        XCTAssertLessThan(elapsed, 5.0, "completion should terminate within 5s of cancel")
        try? await client.unloadModel(modelId: modelId)
    }

    // QVAC-221: graceful shutdown — close() while no operations are pending.
    func test_close_after_idle_terminates_worker() async throws {
        let client = try await makeClient()
        // Idle the client (just a heartbeat).
        _ = try await client.heartbeat()
        let start = Date()
        await client.close()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }
}
#endif
