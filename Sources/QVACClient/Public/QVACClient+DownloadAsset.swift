// QVAC-213 — downloadAsset
//
// Download a model asset (or any HTTPS URL the worker will fetch) to the worker's
// cache without loading it into memory. Returns the asset id (the resolved cache key).
// Optionally exposes a progress stream while downloading.

import Foundation

public extension QVACClient {

    /// Download an asset. Blocking — waits for completion.
    /// Returns the asset id (typically a content-hash-prefixed file path inside the cache).
    @discardableResult
    func downloadAsset(assetSrc: String, seed: Bool = false) async throws -> String {
        var req = DownloadAssetRequest(assetSrc: assetSrc)
        req.seed = seed
        let response: QVACResponse = try await sendTyped(.downloadAsset(req))
        guard case .downloadAsset(let r) = response else {
            throw QVACError.protocolViolation("expected downloadAsset response, got \(response.discriminator)")
        }
        if r.success != true {
            throw QVACError.server(.downloadAssetFailed, message: r.error)
        }
        guard let id = r.assetId else {
            throw QVACError.protocolViolation("downloadAsset: missing assetId")
        }
        return id
    }

    /// Download an asset with progress events. Returns `(progress, assetIdTask)`:
    /// iterate `progress` for `ModelLoadProgress` events; `await assetIdTask` for the
    /// resolved id when done.
    func downloadAssetStreaming(
        assetSrc: String,
        seed: Bool = false
    ) async throws -> (progress: AsyncThrowingStream<ModelLoadProgress, Error>, assetId: Task<String, Error>) {
        var req = DownloadAssetRequest(assetSrc: assetSrc)
        req.seed = seed
        req.withProgress = true
        let payload = try JSONEncoder.qvac.encode(QVACRequest.downloadAsset(req))
        let cmd = nextCommand()
        let rawStream = try await sendStreamRaw(payload: payload, command: cmd)

        let (progressStream, progressContinuation) = Self.makeStream(of: ModelLoadProgress.self)
        let assetIdTask = Task<String, Error> {
            do {
                var buffer = Data()
                for try await chunk in rawStream {
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<nl]
                        buffer.removeSubrange(buffer.startIndex...nl)
                        if lineData.isEmpty { continue }
                        let response = try Self.decodeOrThrowStatic(QVACResponse.self, from: Data(lineData))
                        switch response {
                        case .modelProgress(let p):
                            progressContinuation.yield(ModelLoadProgress(p))
                        case .downloadAsset(let r):
                            progressContinuation.finish()
                            if r.success != true {
                                throw QVACError.server(.downloadAssetFailed, message: r.error)
                            }
                            guard let id = r.assetId else {
                                throw QVACError.protocolViolation("downloadAsset: missing assetId")
                            }
                            return id
                        case .error(let e):
                            throw QVACError.fromWire(code: Int(e.code ?? 0), message: e.message)
                        default:
                            continue
                        }
                    }
                }
                progressContinuation.finish()
                throw QVACError.protocolViolation("downloadAsset stream ended without resolution")
            } catch {
                progressContinuation.finish(throwing: error)
                throw error
            }
        }
        return (progressStream, assetIdTask)
    }
}
