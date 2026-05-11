// QVAC-312 + QVAC-313 — RAG + plugin live integration tests.
//
// Exercises the full RAG pipeline against a real Bare worker:
//   loadModel(embedding model) → ragChunk → ragIngest → ragSearch
//   → ragListWorkspaces → ragDeleteEmbeddings → ragCloseWorkspace
//   → ragDeleteWorkspace → unloadModel
//
// Gated on `QVAC_RUN_RAG_TESTS=1` because they download a ~20MB embedding model.
// Optional `HF_TOKEN` for HuggingFace gated models.

import XCTest
@testable import QVACClient

#if canImport(Darwin)

final class RAGIntegrationTests: XCTestCase {

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

    private static let embeddingModelURL: String = {
        ProcessInfo.processInfo.environment["QVAC_TEST_EMBEDDING_URL"]
            ?? "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf"
    }()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QVAC_RUN_RAG_TESTS"] == "1",
                          "set QVAC_RUN_RAG_TESTS=1 to opt into RAG live tests (requires downloading an embedding model)")
        try XCTSkipUnless(Self.bareBin != nil)
        try XCTSkipUnless(Self.nodeModulesDir != nil)
        if Self.embeddingModelURL.contains("huggingface.co")
            && ProcessInfo.processInfo.environment["HF_TOKEN"] == nil {
            throw XCTSkip("HF model URL requires HF_TOKEN; or set QVAC_TEST_EMBEDDING_URL to a public source")
        }
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.qvac/.worker.lock")
    }

    private func makeClient() async throws -> QVACClient {
        let cfg = try QVACClient.Configuration.macOS(
            nodeModulesDir: Self.nodeModulesDir!, bareExecutable: Self.bareBin!, initTimeout: 30.0
        )
        return try await QVACClient(configuration: cfg)
    }

    // MARK: - ragChunk (no model needed)

    /// Chunking is a pure CPU operation — works without loading any model.
    /// Quick sanity check of the rag pipeline + RagChunk shape decode.
    func test_ragChunk_returns_chunks_for_document() async throws {
        let client = try await makeClient()
        defer { Task { await client.close() } }
        let docs: [QVACClient.RagDocument] = [
            QVACClient.RagDocument("The quick brown fox jumps over the lazy dog. This is a second sentence for chunking.")
        ]
        let chunks = try await client.ragChunk(documents: docs)
        XCTAssertGreaterThan(chunks.count, 0, "expected at least 1 chunk")
        for c in chunks {
            XCTAssertFalse(c.id.isEmpty)
            XCTAssertFalse(c.text.isEmpty)
        }
    }

    // MARK: - Full RAG pipeline (needs embedding model)

    func test_full_RAG_ingest_search_delete_workspace_cycle() async throws {
        let client = try await makeClient()
        defer { Task { await client.close() } }
        let workspace = "qvac-swift-test-\(UUID().uuidString)"

        // 1. Load the embedding model.
        let modelId = try await client.loadModel(
            modelSrc: Self.embeddingModelURL,
            modelType: "llamacpp-embedding"
        )

        defer {
            Task {
                try? await client.ragDeleteWorkspace(workspace: workspace)
                try? await client.unloadModel(modelId: modelId)
            }
        }

        // 2. Ingest 3 short documents.
        let documents: [QVACClient.RagDocument] = [
            .init("Apples are red fruit that grow on trees."),
            .init("Pythons are large nonvenomous snakes."),
            .init("Swift is a programming language by Apple."),
        ]
        let ingestResult = try await client.ragIngest(
            modelId: modelId, documents: documents, workspace: workspace
        )
        XCTAssertGreaterThan(ingestResult.processed.count, 0)

        // 3. Search for a programming-language query — should rank Swift first.
        let results = try await client.ragSearch(
            modelId: modelId, query: "what programming language", topK: 3, workspace: workspace
        )
        XCTAssertGreaterThan(results.count, 0)
        // Top result should mention Swift.
        XCTAssertTrue(results.first?.text.lowercased().contains("swift") ?? false,
                      "expected first result to mention swift; got \(results.first?.text ?? "<nil>")")

        // 4. List workspaces — should contain ours.
        let workspaces = try await client.ragListWorkspaces()
        XCTAssertTrue(workspaces.contains { $0.name == workspace })

        // 5. Close + delete.
        try await client.ragCloseWorkspace(workspace: workspace, deleteOnClose: true)
    }
}

#endif
