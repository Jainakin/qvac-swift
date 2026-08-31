// QVAC-213 — downloadAsset
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
        public let progress: AsyncThrowingStream<ModelLoadProgress, Error>
        public let result: Task<String, Error>

        init(
            requestId: String,
            progress: AsyncThrowingStream<ModelLoadProgress, Error>,
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
        let (progress, progressContinuation) = Self.makeStream(of: ModelLoadProgress.self)
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

        let (progressStream, progressContinuation) = Self.makeStream(of: ModelLoadProgress.self)
        let assetIdTask = Task<String, Error> {
            do {
                for try await response in source {
                    if let id = try Self.handleDownloadAssetResponse(
                        response,
                        progress: progressContinuation
                    ) {
                        return id
                    }
                }
                progressContinuation.finish()
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

    private static func handleDownloadAssetResponse(
        _ response: QVACResponse,
        progress: QVACStreamSink<ModelLoadProgress>
    ) throws -> String? {
        switch response {
        case .modelProgress(let event):
            // Overflow terminates only the optional progress view. Keep draining so
            // the asset-id result remains independent, matching decorated promises.
            progress.yield(ModelLoadProgress(event))
            return nil
        case .downloadAsset(let result):
            progress.finish()
            return try extractDownloadedAssetId(result)
        case .error(let error):
            throw QVACError.fromWire(
                code: try checkedWireErrorCode(error.code),
                message: error.message
            )
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
