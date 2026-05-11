// QVAC-301..309 — RAG (Retrieval-Augmented Generation) operations.
//
// Maps the JS client's 9 RAG functions to typed Swift methods. All share the same
// wire envelope (`type: "rag"`, `operation: <op>`) — we route per-op on the Swift side
// to keep parameter sets ergonomic.
//
// Workspace model: each RAG instance lives in a named workspace (default = "default").
// Workspaces are created implicitly on first `ragIngest`. Use `ragListWorkspaces` to
// enumerate; `ragCloseWorkspace`/`ragDeleteWorkspace` to tear down.

import Foundation

public extension QVACClient {

    // MARK: - Domain types

    /// A document to ingest. Either plain text or a `{text, metadata}` pair.
    struct RagDocument: Sendable, Equatable {
        public let text: String
        public let metadata: JSONValue?
        public init(_ text: String, metadata: JSONValue? = nil) {
            self.text = text; self.metadata = metadata
        }
        var asJSON: JSONValue {
            if let m = metadata {
                return .object(["text": .string(text), "metadata": m])
            }
            return .string(text)
        }
    }

    /// A document chunk produced by `ragChunk` or `ragIngest` (intermediate output).
    struct RagChunk: Sendable, Equatable {
        public let id: String
        public let text: String
        public let metadata: JSONValue?
    }

    /// One search result.
    struct RagSearchResult: Sendable, Equatable {
        public let id: String
        public let text: String
        public let score: Double
        public let metadata: JSONValue?
    }

    /// One workspace entry from `ragListWorkspaces`.
    struct RagWorkspaceInfo: Sendable, Equatable {
        public let name: String
        public let open: Bool
    }

    /// Outcome of `ragIngest` / `ragSaveEmbeddings`.
    struct RagIngestResult: Sendable, Equatable {
        public let processed: [JSONValue]
        public let droppedIndices: [Int]
    }

    // MARK: - 1) ragIngest — chunk + embed + save (full pipeline)

    /// Ingest documents end-to-end: chunk them, embed each chunk, save to the workspace.
    @discardableResult
    func ragIngest(
        modelId: String,
        documents: [RagDocument],
        workspace: String? = nil,
        chunkOpts: JSONValue? = nil
    ) async throws -> RagIngestResult {
        var req = RagRequest(operation: "ingest")
        req.modelId = modelId
        req.documents = documents.map(\.asJSON)
        req.workspace = workspace
        req.chunkOpts = chunkOpts
        return try await runRagAndExtract(req, op: "ingest") { r in
            RagIngestResult(
                processed: r.processed ?? [],
                droppedIndices: (r.droppedIndices ?? []).map { Int($0) }
            )
        }
    }

    // MARK: - 2) ragSearch — top-K vector retrieval

    /// Search the workspace for the `topK` documents most relevant to `query`.
    /// Empty `results` is the expected response when the workspace doesn't exist
    /// (matches JS behavior — silent rather than throwing).
    func ragSearch(
        modelId: String,
        query: String,
        topK: Int = 5,
        workspace: String? = nil
    ) async throws -> [RagSearchResult] {
        var req = RagRequest(operation: "search")
        req.modelId = modelId
        req.query = query
        req.topK = Double(topK)
        req.workspace = workspace
        return try await runRagAndExtract(req, op: "search") { r in
            (r.results ?? []).compactMap { Self.parseRagSearchResult($0) }
        }
    }

    // MARK: - 3) ragChunk — standalone chunking (no embed, no save)

    /// Run the chunker over `documents` and return the chunks.
    func ragChunk(documents: [RagDocument], chunkOpts: JSONValue? = nil) async throws -> [RagChunk] {
        var req = RagRequest(operation: "chunk")
        req.documents = documents.map(\.asJSON)
        req.chunkOpts = chunkOpts
        return try await runRagAndExtract(req, op: "chunk") { r in
            (r.chunks ?? []).compactMap { Self.parseRagChunk($0) }
        }
    }

    // MARK: - 4) ragSaveEmbeddings — save pre-embedded docs (skip chunk + embed steps)

    /// Save documents that you've already embedded externally (e.g. you ran `embed` yourself
    /// and want to persist the vectors).
    @discardableResult
    func ragSaveEmbeddings(
        documents: [JSONValue],
        modelId: String? = nil,
        workspace: String? = nil
    ) async throws -> RagIngestResult {
        var req = RagRequest(operation: "saveEmbeddings")
        req.documents = documents
        req.modelId = modelId
        req.workspace = workspace
        return try await runRagAndExtract(req, op: "saveEmbeddings") { r in
            RagIngestResult(
                processed: r.processed ?? [],
                droppedIndices: (r.droppedIndices ?? []).map { Int($0) }
            )
        }
    }

    // MARK: - 5) ragDeleteEmbeddings — delete by ids

    /// Delete embeddings by document id from `workspace`.
    /// Throws `QVACError.server(.ragWorkspaceNotFound, …)` if the workspace doesn't exist.
    func ragDeleteEmbeddings(ids: [String], workspace: String? = nil) async throws {
        var req = RagRequest(operation: "deleteEmbeddings")
        req.ids = ids
        req.workspace = workspace
        _ = try await runRagAndExtract(req, op: "deleteEmbeddings") { _ in () }
    }

    // MARK: - 6) ragListWorkspaces

    /// List all workspaces (open + closed).
    func ragListWorkspaces() async throws -> [RagWorkspaceInfo] {
        let req = RagRequest(operation: "listWorkspaces")
        return try await runRagAndExtract(req, op: "listWorkspaces") { r in
            (r.workspaces ?? []).compactMap { Self.parseWorkspaceInfo($0) }
        }
    }

    // MARK: - 7) ragCloseWorkspace

    /// Close a workspace, optionally deleting it on the way out.
    func ragCloseWorkspace(workspace: String? = nil, deleteOnClose: Bool = false) async throws {
        var req = RagRequest(operation: "closeWorkspace")
        req.workspace = workspace
        req.deleteOnClose = deleteOnClose
        _ = try await runRagAndExtract(req, op: "closeWorkspace") { _ in () }
    }

    // MARK: - 8) ragDeleteWorkspace

    /// Delete a workspace. Throws if the workspace is currently loaded — close it first.
    func ragDeleteWorkspace(workspace: String) async throws {
        var req = RagRequest(operation: "deleteWorkspace")
        req.workspace = workspace
        _ = try await runRagAndExtract(req, op: "deleteWorkspace") { _ in () }
    }

    // MARK: - 9) ragReindex — k-means cluster optimization

    /// Reindex `workspace` to optimize search. `n` is the target cluster count;
    /// `nil` lets the worker pick.
    func ragReindex(workspace: String? = nil, n: Int? = nil) async throws -> JSONValue? {
        var req = RagRequest(operation: "reindex")
        req.workspace = workspace
        req.n = n.map { Double($0) }
        return try await runRagAndExtract(req, op: "reindex") { $0.result }
    }

    // MARK: - Internal

    private func runRagAndExtract<T>(_ req: RagRequest, op: String, extractor: (RagResponse) -> T) async throws -> T {
        let response: QVACResponse = try await sendTyped(.rag(req))
        guard case .rag(let r) = response else {
            throw QVACError.protocolViolation("expected rag response, got \(response.discriminator)")
        }
        guard r.operation == op else {
            throw QVACError.protocolViolation("rag response operation \(r.operation) ≠ \(op)")
        }
        if r.success != true {
            throw QVACError.server(.ragHyperdbFailed, message: r.error)
        }
        return extractor(r)
    }

    // MARK: - JSON parsing helpers

    private static func parseRagChunk(_ value: JSONValue) -> RagChunk? {
        guard case .object(let obj) = value,
              case .string(let id) = obj["id"] ?? .null,
              case .string(let text) = obj["text"] ?? .null
        else { return nil }
        return RagChunk(id: id, text: text, metadata: obj["metadata"])
    }

    private static func parseRagSearchResult(_ value: JSONValue) -> RagSearchResult? {
        guard case .object(let obj) = value,
              case .string(let id) = obj["id"] ?? .null,
              case .string(let text) = obj["text"] ?? .null,
              case .number(let score) = obj["score"] ?? .null
        else { return nil }
        return RagSearchResult(id: id, text: text, score: score, metadata: obj["metadata"])
    }

    private static func parseWorkspaceInfo(_ value: JSONValue) -> RagWorkspaceInfo? {
        guard case .object(let obj) = value,
              case .string(let name) = obj["name"] ?? .null,
              case .bool(let open) = obj["open"] ?? .null
        else { return nil }
        return RagWorkspaceInfo(name: name, open: open)
    }
}
