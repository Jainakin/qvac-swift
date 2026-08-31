// QVAC-312 + QVAC-313 — RAG + plugin live integration tests.
//
// Exercises the full RAG pipeline against a real Bare worker:
//   loadModel(embedding model) → ragChunk → ragIngest → ragSearch
//   → ragListWorkspaces → ragDeleteEmbeddings → ragCloseWorkspace
//   → ragDeleteWorkspace → unloadModel
//
// Gated on `QVAC_RUN_RAG_TESTS=1` because they download a 20,999,104-byte
// public embedding model. The immutable revision and SHA-256 are verified first.

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

    private var workerHome: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QVAC_RUN_RAG_TESTS"] == "1",
                          "set QVAC_RUN_RAG_TESTS=1 to opt into RAG live tests (requires downloading an embedding model)")
        guard let bare = Self.bareBin, FileManager.default.isExecutableFile(atPath: bare.path) else {
            throw IntegrationPrerequisiteError("QVAC_RUN_RAG_TESTS=1 but QVAC_BARE_BIN is missing or not executable")
        }
        guard let modules = Self.nodeModulesDir, FileManager.default.fileExists(atPath: modules.path) else {
            throw IntegrationPrerequisiteError("QVAC_RUN_RAG_TESTS=1 but QVAC_NODE_MODULES is missing")
        }
        try Self.requireSDK017(in: modules)
        _ = try Self.fixture()
        workerHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("qvac-rag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workerHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workerHome { try? FileManager.default.removeItem(at: workerHome) }
    }

    private static func fixture() throws -> VerifiedModelFixture {
        try VerifiedModelFixture.fromEnvironment(
            default: .embeddingModelDefault,
            urlKey: "QVAC_TEST_EMBEDDING_URL",
            sha256Key: "QVAC_TEST_EMBEDDING_SHA256",
            sizeKey: "QVAC_TEST_EMBEDDING_SIZE"
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
            initTimeout: 30.0,
            homeDir: workerHome.path
        ))
        return try await QVACClient(
            configuration: cfg,
            initHandshakeTimeout: .seconds(30)
        )
    }

    // MARK: - ragChunk (no model needed)

    /// Chunking is a pure CPU operation — works without loading any model.
    /// Quick sanity check of the rag pipeline + RagChunk shape decode.
    func test_ragChunk_returns_chunks_for_document() async throws {
        let client = try await makeClient()
        addTeardownBlock { await client.close() }
        let docs = [
            "The quick brown fox jumps over the lazy dog. This is a second sentence for chunking."
        ]
        let chunks = try await client.ragChunk(
            documents: docs,
            rpcOptions: .init(timeout: .seconds(120))
        )
        XCTAssertGreaterThan(chunks.count, 0, "expected at least 1 chunk")
        for c in chunks {
            XCTAssertFalse(c.id.isEmpty)
            XCTAssertFalse(c.content.isEmpty)
        }
    }

    // MARK: - Full RAG pipeline (needs embedding model)

    func test_full_RAG_ingest_search_delete_workspace_cycle() async throws {
        let client = try await makeClient()
        addTeardownBlock { await client.close() }
        let workspace = "qvac-swift-test-\(UUID().uuidString)"
        let modelURL = try await Self.fixture().localURL()

        // 1. Load the embedding model.
        let load = try await client.loadModel(
            modelSrc: modelURL.path,
            modelType: "llamacpp-embedding",
            rpcOptions: .init(timeout: .seconds(600))
        )
        let modelId = try await load.result.value

        do {
            // 2. Ingest 3 short documents.
            let documents = [
                "Apples are red fruit that grow on trees.",
                "Pythons are large nonvenomous snakes.",
                "Swift is a programming language by Apple.",
            ]
            let ingest = try await client.ragIngest(
                modelId: modelId,
                documents: documents,
                workspace: workspace,
                rpcOptions: .init(timeout: .seconds(120))
            )
            let ingestResult = try await ingest.result.value
            XCTAssertGreaterThan(ingestResult.processed.count, 0)

            // 3. Search for a programming-language query — should rank Swift first.
            let results = try await client.ragSearch(
                modelId: modelId,
                query: "what programming language",
                topK: 3,
                n: 3,
                workspace: workspace,
                rpcOptions: .init(timeout: .seconds(120))
            )
            XCTAssertGreaterThan(results.count, 0)
            XCTAssertTrue(results.first?.content.lowercased().contains("swift") ?? false,
                          "expected first result to mention swift; got \(results.first?.content ?? "<nil>")")

            // 4. List workspaces — should contain ours.
            let workspaces = try await client.ragListWorkspaces(
                rpcOptions: .init(timeout: .seconds(120))
            )
            XCTAssertTrue(workspaces.contains { $0.name == workspace })

            // 5. Close/delete and unload are part of the required success path.
            try await client.ragCloseWorkspace(
                workspace: workspace,
                deleteOnClose: true,
                rpcOptions: .init(timeout: .seconds(10))
            )
            try await client.unloadModel(
                modelId: modelId,
                rpcOptions: .init(timeout: .seconds(10))
            )
        } catch let operationError {
            do {
                try await client.ragCloseWorkspace(
                    workspace: workspace,
                    deleteOnClose: true,
                    rpcOptions: .init(timeout: .seconds(10))
                )
            } catch let closeError {
                do {
                    try await client.ragDeleteWorkspace(
                        workspace: workspace,
                        rpcOptions: .init(timeout: .seconds(10))
                    )
                } catch {
                    XCTFail(
                        "RAG failure cleanup could neither close/delete workspace "
                        + "(close: \(closeError), delete: \(error))"
                    )
                }
            }
            do {
                try await client.unloadModel(
                    modelId: modelId,
                    rpcOptions: .init(timeout: .seconds(10))
                )
            } catch {
                XCTFail("RAG failure cleanup could not unload model: \(error)")
            }
            throw operationError
        }
    }
}

#endif
