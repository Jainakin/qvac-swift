// Asset downloads.
//
// Download a model asset (or any HTTPS URL the worker will fetch) to the worker's
// cache without loading it into memory. Returns the asset id (the resolved cache key).
// Optionally exposes a progress stream while downloading.

import Foundation

public extension QVACClient {

    /// A cancellable asset download matching the decorated promise returned by the
    /// published 0.17 JavaScript client.
    final class AssetDownloadRun: @unchecked Sendable {
        public let requestId: String
        /// Byte-bounded observational progress retaining the newest window if lagging.
        public let progress: QVACBufferedStream<ModelLoadProgress>
        public let result: Task<String, Error>

        init(
            requestId: String,
            progress: QVACBufferedStream<ModelLoadProgress>,
            result: Task<String, Error>
        ) {
            self.requestId = requestId
            self.progress = progress
            self.result = result
        }
    }

    /// Start a non-progress asset download. The run exposes its targeted-cancel id
    /// immediately and resolves to the asset id through ``AssetDownloadRun/result``.
    @discardableResult
    func downloadAsset(
        assetSrc: String,
        seed: Bool = false,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> AssetDownloadRun {
        let requestId = UUID().uuidString
        var req = DownloadAssetRequest(assetSrc: assetSrc)
        req.requestId = requestId
        req.seed = seed
        let (progress, progressContinuation) = Self.makeCoalescingProgressStream(
            of: ModelLoadProgress.self,
            name: "downloadAsset.progress",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )
        progressContinuation.finish()
        let result = Task<String, Error> {
            let response: QVACResponse = try await self.sendTyped(
                .downloadAsset(req), rpcOptions: rpcOptions
            )
            guard case .downloadAsset(let terminal) = response else {
                throw QVACError.protocolViolation(
                    "expected downloadAsset response, got \(response.discriminator)"
                )
            }
            return try Self.extractDownloadedAssetId(terminal)
        }
        return AssetDownloadRun(requestId: requestId, progress: progress, result: result)
    }

    /// Download an asset described by the same 0.17 model-source descriptor accepted
    /// by `@qvac/sdk`. The JavaScript request transform deliberately sends only the
    /// descriptor's `src` value for `downloadAsset`; the remaining descriptor metadata
    /// is registry/catalog metadata and is not part of this operation's wire schema.
    @discardableResult
    func downloadAsset(
        assetSrc: ModelDescriptor,
        seed: Bool = false,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> AssetDownloadRun {
        try await downloadAsset(
            assetSrc: assetSrc.src,
            seed: seed,
            rpcOptions: rpcOptions
        )
    }

    /// Download an asset with progress events. Cancelling the run's result task
    /// deterministically destroys the underlying RPC stream.
    func downloadAssetStreaming(
        assetSrc: String,
        seed: Bool = false,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> AssetDownloadRun {
        let requestId = UUID().uuidString
        var req = DownloadAssetRequest(assetSrc: assetSrc)
        req.requestId = requestId
        req.seed = seed
        req.withProgress = true
        let source: QVACResponseStream<QVACResponse> = try await streamTyped(
            .downloadAsset(req),
            rpcOptions: rpcOptions
        )

        let maximumBufferedStreamBytes = self.maximumBufferedStreamBytes
        let (progressStream, progressContinuation) = Self.makeCoalescingProgressStream(
            of: ModelLoadProgress.self,
            name: "downloadAsset.progress",
            maximumBufferedBytes: maximumBufferedStreamBytes
        )
        let assetIdTask = Task<String, Error> {
            do {
                let responses = QVACResponseStreamIteratorBox(source)
                while let response = try await responses.next() {
                    if let terminal = try Self.handleDownloadAssetResponse(
                        response,
                        progress: progressContinuation,
                        maximumBufferedStreamBytes: maximumBufferedStreamBytes
                    ) {
                        let id = try await Self.resolveResponseStreamTerminal(
                            responses,
                            operation: "downloadAsset"
                        ) {
                            try terminal.get()
                        }
                        progressContinuation.finish()
                        return id
                    }
                }
                throw QVACError.protocolViolation("downloadAsset stream ended without resolution")
            } catch {
                let publicError = Self.publicRPCError(error, operation: "downloadAsset")
                progressContinuation.finish(throwing: publicError)
                throw publicError
            }
        }
        return AssetDownloadRun(
            requestId: requestId,
            progress: progressStream,
            result: assetIdTask
        )
    }

    /// Streaming counterpart to the descriptor download overload. Progress,
    /// cancellation, timeout, and profiling behavior are identical to the
    /// string-source overload.
    func downloadAssetStreaming(
        assetSrc: ModelDescriptor,
        seed: Bool = false,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> AssetDownloadRun {
        try await downloadAssetStreaming(
            assetSrc: assetSrc.src,
            seed: seed,
            rpcOptions: rpcOptions
        )
    }

    private static func handleDownloadAssetResponse(
        _ response: QVACResponse,
        progress: QVACBufferedStreamSink<ModelLoadProgress>,
        maximumBufferedStreamBytes: Int
    ) throws -> Result<String, Error>? {
        switch response {
        case .modelProgress(let event):
            // Progress snapshots coalesce if the observer lags. Keep draining so the
            // asset-id result remains independent, matching decorated promises.
            progress.yield(
                contentsOf: [try ModelLoadProgress(event)],
                estimatedBytes: conservativeBufferedJSONBytes(
                    event,
                    elementCount: 1,
                    fallback: maximumBufferedStreamBytes
                )
            )
            return nil
        case .downloadAsset(let result):
            return Result { try extractDownloadedAssetId(result) }
        case .error(let error):
            return .failure(retainedWireError(error))
        default:
            try rejectUnexpectedResponse(
                response,
                expected: "downloadAsset or modelProgress"
            )
        }
    }

    private static func extractDownloadedAssetId(
        _ result: DownloadAssetResponse
    ) throws -> String {
        guard result.success == true else {
            throw QVACError.server(.downloadAssetFailed, message: result.error)
        }
        guard let id = result.assetId else {
            throw QVACError.protocolViolation("downloadAsset: missing assetId")
        }
        return id
    }
}
