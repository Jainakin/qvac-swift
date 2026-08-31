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

    /// Chunking controls accepted by QVAC SDK 0.17.
    struct RagChunkOptions: Sendable, Equatable {
        public enum ChunkStrategy: String, Sendable {
            case character
            case paragraph
        }

        public enum SplitStrategy: String, Sendable {
            case character
            case word
            case token
            case sentence
            case line
        }

        public let chunkSize: Double?
        public let chunkOverlap: Double?
        public let chunkStrategy: ChunkStrategy?
        public let splitStrategy: SplitStrategy?

        public init(
            chunkSize: Double? = nil,
            chunkOverlap: Double? = nil,
            chunkStrategy: ChunkStrategy? = nil,
            splitStrategy: SplitStrategy? = nil
        ) {
            self.chunkSize = chunkSize
            self.chunkOverlap = chunkOverlap
            self.chunkStrategy = chunkStrategy
            self.splitStrategy = splitStrategy
        }

        fileprivate var wireValue: JSONValue {
            var object: [String: JSONValue] = [:]
            if let chunkSize { object["chunkSize"] = .number(chunkSize) }
            if let chunkOverlap { object["chunkOverlap"] = .number(chunkOverlap) }
            if let chunkStrategy { object["chunkStrategy"] = .string(chunkStrategy.rawValue) }
            if let splitStrategy { object["splitStrategy"] = .string(splitStrategy.rawValue) }
            return .object(object)
        }
    }

    /// A document chunk produced by ``ragChunk(documents:chunkOpts:rpcOptions:)``.
    struct RagChunk: Sendable, Equatable {
        public let id: String
        public let content: String
    }

    /// One search result.
    struct RagSearchResult: Sendable, Equatable {
        public let id: String
        public let content: String
        public let score: Double
    }

    /// A pre-embedded document accepted by `ragSaveEmbeddings`.
    struct RagEmbeddedDocument: Sendable, Equatable {
        public let id: String
        public let content: String
        public let embedding: [Double]
        public let embeddingModelId: String
        public let metadata: [String: JSONValue]?

        public init(
            id: String,
            content: String,
            embedding: [Double],
            embeddingModelId: String,
            metadata: [String: JSONValue]? = nil
        ) {
            self.id = id
            self.content = content
            self.embedding = embedding
            self.embeddingModelId = embeddingModelId
            self.metadata = metadata
        }

        fileprivate var wireValue: JSONValue {
            var object: [String: JSONValue] = [
                "id": .string(id),
                "content": .string(content),
                "embedding": .array(embedding.map(JSONValue.number)),
                "embeddingModelId": .string(embeddingModelId),
            ]
            if let metadata { object["metadata"] = .object(metadata) }
            return .object(object)
        }
    }

    /// Per-document storage outcome returned by ingest/save operations.
    struct RagSaveResult: Sendable, Equatable {
        public enum Status: String, Sendable {
            case fulfilled
            case rejected
        }

        public let status: Status
        public let id: String?
        public let error: String?
    }

    /// One workspace entry from `ragListWorkspaces`.
    struct RagWorkspaceInfo: Sendable, Equatable {
        public let name: String
        public let open: Bool
    }

    /// Outcome of `ragIngest` / `ragSaveEmbeddings`.
    struct RagIngestResult: Sendable, Equatable {
        public let processed: [RagSaveResult]
        public let droppedIndices: [Int]
    }

    /// Outcome of a workspace reindex operation.
    struct RagReindexResult: Sendable, Equatable {
        public let reindexed: Bool
        public let details: [String: JSONValue]?
    }

    /// A cancellable RAG ingest/save/reindex operation matching the published 0.17
    /// decorated-promise contract.
    final class RagOperationRun<Output: Sendable>: @unchecked Sendable {
        public let requestId: String
        public let progress: AsyncThrowingStream<RagProgressResponse, Error>
        public let result: Task<Output, Error>

        init(
            requestId: String,
            progress: AsyncThrowingStream<RagProgressResponse, Error>,
            result: Task<Output, Error>
        ) {
            self.requestId = requestId
            self.progress = progress
            self.result = result
        }
    }

    // MARK: - 1) ragIngest — chunk + embed + save (full pipeline)

    /// Ingest documents end-to-end: chunk them, embed each chunk, save to the workspace.
    @discardableResult
    func ragIngest(
        modelId: String,
        documents: [String],
        workspace: String? = nil,
        chunk: Bool = true,
        chunkOpts: RagChunkOptions? = nil,
        withProgress: Bool = false,
        progressInterval: Double? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> RagOperationRun<RagIngestResult> {
        var req = RagRequest(operation: "ingest")
        req.modelId = modelId
        req.documents = documents.map(JSONValue.string)
        req.workspace = workspace
        req.chunk = chunk
        req.chunkOpts = chunkOpts?.wireValue
        req.withProgress = withProgress ? true : nil
        req.progressInterval = progressInterval
        return try await makeRagRun(req, op: "ingest", rpcOptions: rpcOptions) { r in
            guard let processed = r.processed, let droppedIndices = r.droppedIndices else {
                throw QVACError.protocolViolation(
                    "rag ingest response omitted processed or droppedIndices"
                )
            }
            return RagIngestResult(
                processed: try processed.map(Self.parseRagSaveResult),
                droppedIndices: try droppedIndices.map {
                    try Self.checkedWireInteger($0, field: "rag.ingest.droppedIndices")
                }
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
        n: Int = 3,
        workspace: String? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> [RagSearchResult] {
        guard !query.isEmpty else {
            throw QVACError.invalidArgument("rag search query must not be empty")
        }
        guard topK > 0 else {
            throw QVACError.invalidArgument("rag search topK must be greater than zero")
        }
        guard n > 0 else {
            throw QVACError.invalidArgument("rag search n must be greater than zero")
        }
        var req = RagRequest(operation: "search")
        req.modelId = modelId
        req.query = query
        req.topK = Double(topK)
        req.n = Double(n)
        req.workspace = workspace
        return try await runRagAndExtract(req, op: "search", rpcOptions: rpcOptions) { r in
            guard let results = r.results else {
                throw QVACError.protocolViolation("rag search response omitted results")
            }
            return try results.map(Self.parseRagSearchResult)
        }
    }

    // MARK: - 3) ragChunk — standalone chunking (no embed, no save)

    /// Run the chunker over `documents` and return the chunks.
    func ragChunk(
        documents: [String],
        chunkOpts: RagChunkOptions? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> [RagChunk] {
        var req = RagRequest(operation: "chunk")
        req.documents = documents.map(JSONValue.string)
        req.chunkOpts = chunkOpts?.wireValue
        return try await runRagAndExtract(req, op: "chunk", rpcOptions: rpcOptions) { r in
            guard let chunks = r.chunks else {
                throw QVACError.protocolViolation("rag chunk response omitted chunks")
            }
            return try chunks.map(Self.parseRagChunk)
        }
    }

    // MARK: - 4) ragSaveEmbeddings — save pre-embedded docs (skip chunk + embed steps)

    /// Save documents that you've already embedded externally (e.g. you ran `embed` yourself
    /// and want to persist the vectors).
    @discardableResult
    func ragSaveEmbeddings(
        documents: [RagEmbeddedDocument],
        modelId: String? = nil,
        workspace: String? = nil,
        withProgress: Bool = false,
        progressInterval: Double? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> RagOperationRun<[RagSaveResult]> {
        var req = RagRequest(operation: "saveEmbeddings")
        req.documents = documents.map(\.wireValue)
        req.modelId = modelId
        req.workspace = workspace
        req.withProgress = withProgress ? true : nil
        req.progressInterval = progressInterval
        return try await makeRagRun(
            req,
            op: "saveEmbeddings",
            rpcOptions: rpcOptions
        ) { r in
            guard let processed = r.processed else {
                throw QVACError.protocolViolation("rag saveEmbeddings response omitted processed")
            }
            return try processed.map(Self.parseRagSaveResult)
        }
    }

    // MARK: - 5) ragDeleteEmbeddings — delete by ids

    /// Delete embeddings by document id from `workspace`.
    /// Matches the 0.17 JavaScript client by throwing
    /// `QVACError.server(.ragDeleteFailed, …)` when deletion fails, including when
    /// the workspace has not been initialized.
    func ragDeleteEmbeddings(
        ids: [String],
        workspace: String? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws {
        guard !ids.isEmpty else {
            throw QVACError.invalidArgument("rag deleteEmbeddings ids must not be empty")
        }
        var req = RagRequest(operation: "deleteEmbeddings")
        req.ids = ids
        req.workspace = workspace
        _ = try await runRagAndExtract(req, op: "deleteEmbeddings", rpcOptions: rpcOptions) { _ in () }
    }

    // MARK: - 6) ragListWorkspaces

    /// List all workspaces (open + closed).
    func ragListWorkspaces(rpcOptions: QVACRPCOptions = .init()) async throws -> [RagWorkspaceInfo] {
        let req = RagRequest(operation: "listWorkspaces")
        return try await runRagAndExtract(req, op: "listWorkspaces", rpcOptions: rpcOptions) { r in
            guard let workspaces = r.workspaces else {
                throw QVACError.protocolViolation("rag listWorkspaces response omitted workspaces")
            }
            return try workspaces.map(Self.parseWorkspaceInfo)
        }
    }

    // MARK: - 7) ragCloseWorkspace

    /// Close a workspace, optionally deleting it on the way out.
    func ragCloseWorkspace(
        workspace: String? = nil,
        deleteOnClose: Bool = false,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws {
        var req = RagRequest(operation: "closeWorkspace")
        req.workspace = workspace
        req.deleteOnClose = deleteOnClose
        _ = try await runRagAndExtract(req, op: "closeWorkspace", rpcOptions: rpcOptions) { _ in () }
    }

    // MARK: - 8) ragDeleteWorkspace

    /// Delete a workspace. Throws if the workspace is currently loaded — close it first.
    func ragDeleteWorkspace(
        workspace: String,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws {
        guard !workspace.isEmpty else {
            throw QVACError.invalidArgument("rag deleteWorkspace workspace must not be empty")
        }
        var req = RagRequest(operation: "deleteWorkspace")
        req.workspace = workspace
        _ = try await runRagAndExtract(req, op: "deleteWorkspace", rpcOptions: rpcOptions) { _ in () }
    }

    // MARK: - 9) ragReindex — k-means cluster optimization

    /// Reindex `workspace` to optimize search.
    func ragReindex(
        workspace: String? = nil,
        withProgress: Bool = false,
        progressInterval: Double? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> RagOperationRun<RagReindexResult> {
        var req = RagRequest(operation: "reindex")
        req.workspace = workspace
        req.withProgress = withProgress ? true : nil
        req.progressInterval = progressInterval
        return try await makeRagRun(req, op: "reindex", rpcOptions: rpcOptions) { response in
            guard let result = response.result else {
                throw QVACError.protocolViolation("rag reindex response omitted result")
            }
            return try Self.parseRagReindexResult(result)
        }
    }

    // MARK: - Internal

    private func makeRagRun<Output: Sendable>(
        _ input: RagRequest,
        op: String,
        rpcOptions: QVACRPCOptions,
        extractor: @escaping @Sendable (RagResponse) throws -> Output
    ) async throws -> RagOperationRun<Output> {
        var request = input
        let requestId = UUID().uuidString
        request.requestId = requestId
        let (progress, progressSink) = Self.makeStream(
            of: RagProgressResponse.self,
            name: "rag:\(op):progress"
        )

        if request.withProgress == true {
            let source: QVACResponseStream<QVACResponse> = try await streamTyped(
                .rag(request),
                rpcOptions: rpcOptions
            )
            let result = Task<Output, Error> {
                do {
                    for try await response in source {
                        switch response {
                        case .ragProgress(let event):
                            guard event.operation == op else {
                                throw QVACError.protocolViolation(
                                    "rag \(op) received progress for \(event.operation)"
                                )
                            }
                            // Progress is an optional bounded view. If it overflows,
                            // the sink terminates that view explicitly while this task
                            // continues draining toward the authoritative result.
                            progressSink.yield(event)
                        case .rag(let terminal):
                            let validated = try Self.validateRagResponse(terminal, op: op)
                            progressSink.finish()
                            return try extractor(validated)
                        case .error(let error):
                            throw QVACError.fromWire(
                                code: try Self.checkedWireErrorCode(error.code),
                                message: error.message
                            )
                        default:
                            try Self.rejectUnexpectedResponse(
                                response,
                                expected: "rag or rag:progress"
                            )
                        }
                    }
                    throw QVACError.client(
                        .streamEndedWithoutResponse,
                        message: "rag \(op) stream ended without a terminal response"
                    )
                } catch {
                    progressSink.finish(throwing: error)
                    throw error
                }
            }
            return RagOperationRun(
                requestId: requestId,
                progress: progress,
                result: result
            )
        }

        progressSink.finish()
        let result = Task<Output, Error> {
            let response: QVACResponse = try await self.sendTyped(
                .rag(request),
                rpcOptions: rpcOptions
            )
            guard case .rag(let terminal) = response else {
                throw QVACError.protocolViolation(
                    "expected rag response, got \(response.discriminator)"
                )
            }
            return try extractor(Self.validateRagResponse(terminal, op: op))
        }
        return RagOperationRun(requestId: requestId, progress: progress, result: result)
    }

    private func runRagAndExtract<T>(
        _ req: RagRequest,
        op: String,
        rpcOptions: QVACRPCOptions,
        extractor: (RagResponse) throws -> T
    ) async throws -> T {
        let response: QVACResponse = try await sendTyped(.rag(req), rpcOptions: rpcOptions)
        guard case .rag(let r) = response else {
            throw QVACError.protocolViolation("expected rag response, got \(response.discriminator)")
        }
        return try extractor(try Self.validateRagResponse(r, op: op))
    }

    private static func validateRagResponse(
        _ response: RagResponse,
        op: String
    ) throws -> RagResponse {
        guard response.operation == op else {
            throw QVACError.protocolViolation(
                "rag response operation \(response.operation) ≠ \(op)"
            )
        }
        guard response.success == true else {
            let code: QVACErrorCode
            switch op {
            case "chunk": code = .ragChunkFailed
            case "ingest", "saveEmbeddings": code = .ragSaveFailed
            case "search": code = .ragSearchFailed
            case "deleteEmbeddings", "deleteWorkspace": code = .ragDeleteFailed
            case "closeWorkspace": code = .ragWorkspaceCloseFailed
            case "listWorkspaces": code = .ragListWorkspacesFailed
            default: code = .ragHyperdbFailed
            }
            throw QVACError.server(code, message: response.error)
        }
        return response
    }

    // MARK: - JSON parsing helpers

    private static func parseRagChunk(_ value: JSONValue) throws -> RagChunk {
        guard case .object(let obj) = value,
              case .string(let id) = obj["id"] ?? .null,
              case .string(let content) = obj["content"] ?? .null
        else {
            throw QVACError.protocolViolation("rag chunk must contain string id and content")
        }
        return RagChunk(id: id, content: content)
    }

    private static func parseRagSearchResult(_ value: JSONValue) throws -> RagSearchResult {
        guard case .object(let obj) = value,
              case .string(let id) = obj["id"] ?? .null,
              case .string(let content) = obj["content"] ?? .null,
              case .number(let score) = obj["score"] ?? .null
        else {
            throw QVACError.protocolViolation(
                "rag search result must contain string id/content and numeric score"
            )
        }
        guard score.isFinite else {
            throw QVACError.protocolViolation("rag search score must be finite")
        }
        return RagSearchResult(id: id, content: content, score: score)
    }

    private static func parseRagSaveResult(_ value: JSONValue) throws -> RagSaveResult {
        guard case .object(let object) = value,
              case .string(let rawStatus) = object["status"] ?? .null,
              let status = RagSaveResult.Status(rawValue: rawStatus)
        else {
            throw QVACError.protocolViolation(
                "rag save result must contain fulfilled or rejected status"
            )
        }
        let id: String?
        if case .string(let value) = object["id"] { id = value } else { id = nil }
        let error: String?
        if case .string(let value) = object["error"] { error = value } else { error = nil }
        return RagSaveResult(status: status, id: id, error: error)
    }

    private static func parseRagReindexResult(_ value: JSONValue) throws -> RagReindexResult {
        guard case .object(let object) = value,
              case .bool(let reindexed) = object["reindexed"] ?? .null
        else {
            throw QVACError.protocolViolation("rag reindex result must contain reindexed")
        }
        let details: [String: JSONValue]?
        if case .object(let value) = object["details"] { details = value } else { details = nil }
        return RagReindexResult(reindexed: reindexed, details: details)
    }

    private static func parseWorkspaceInfo(_ value: JSONValue) throws -> RagWorkspaceInfo {
        guard case .object(let obj) = value,
              case .string(let name) = obj["name"] ?? .null,
              case .bool(let open) = obj["open"] ?? .null
        else {
            throw QVACError.protocolViolation("rag workspace must contain string name and bool open")
        }
        return RagWorkspaceInfo(name: name, open: open)
    }
}
