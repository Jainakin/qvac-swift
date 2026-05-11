// QVAC-216 — cancel
//
// Aborts an in-progress operation by routing key. Three operation types are supported,
// each with its own keying scheme:
//
//   • `.inference(modelId:)`  — abort any in-flight inference on the named model
//   • `.downloadAsset(downloadKey:, clearCache:)` — pause a download (optionally deleting partial file)
//   • `.rag(workspace:)` — abort RAG ops on a workspace (defaults to "default")
//
// Returns normally on success (worker acked the cancel). Throws `QVACError.server` if the
// operation wasn't found or couldn't be cancelled.

import Foundation

public extension QVACClient {

    /// The kind of operation to cancel. Maps to the JS client's `cancel({operation, ...})`.
    enum CancelOperation: Sendable {
        case inference(modelId: String)
        case downloadAsset(downloadKey: String, clearCache: Bool = false)
        case rag(workspace: String? = nil)
    }

    /// Cancel a previously-started operation.
    ///
    /// Note: cancellation is itself an RPC — the worker has to ack it. If the operation
    /// doesn't exist (already finished, wrong id, etc.) the worker returns
    /// `success: false` with an error; we surface that as `QVACError.server`.
    func cancel(_ operation: CancelOperation) async throws {
        var req = CancelRequest(operation: "")
        switch operation {
        case .inference(let modelId):
            req.operation = "inference"
            req.modelId = modelId
        case .downloadAsset(let downloadKey, let clearCache):
            req.operation = "downloadAsset"
            req.downloadKey = downloadKey
            req.clearCache = clearCache
        case .rag(let workspace):
            req.operation = "rag"
            if let w = workspace { req.workspace = w }
        }
        let response: QVACResponse = try await sendTyped(.cancel(req))
        guard case .cancel(let r) = response else {
            throw QVACError.protocolViolation("expected cancel response, got \(response.discriminator)")
        }
        if r.success == false {
            // Server reported the cancellation failed (most commonly "not found").
            // Map to a generic server error preserving the message.
            throw QVACError.server(.cancelFailed, message: r.error)
        }
    }
}
