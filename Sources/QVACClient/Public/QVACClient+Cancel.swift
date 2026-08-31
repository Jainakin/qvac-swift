// QVAC 0.17 — cancel

import Foundation

public extension QVACClient {

    /// Successful acknowledgement from the worker's request registry.
    /// `cancelled` is the number of live contexts transitioned to cancelling;
    /// zero can also mean the cancel-before-begin race guard recorded the target.
    struct CancelAcknowledgement: Sendable, Equatable {
        public let cancelled: Int?
    }

    /// A native QVAC 0.17 cancellation target.
    ///
    /// - `request` targets one in-flight request by the request id returned from a
    ///   long-running operation. `clearCache` is meaningful for downloads only.
    /// - `broad` cancels every in-flight request for a model, optionally narrowed
    ///   to a worker-defined request kind.
    enum CancelOperation: Sendable, Equatable {
        case request(requestId: String, clearCache: Bool? = nil)
        case broad(modelId: String, kind: String? = nil)
    }

    /// Cancel an in-flight request or a group of requests associated with a model.
    /// Cancellation is itself an RPC and completes only after the worker replies.
    @discardableResult
    func cancel(
        _ operation: CancelOperation,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> CancelAcknowledgement {
        let request = Self.makeCancelRequest(operation)

        let response: QVACResponse = try await sendTyped(.cancel(request), rpcOptions: rpcOptions)
        guard case .cancel(let result) = response else {
            throw QVACError.protocolViolation("expected cancel response, got \(response.discriminator)")
        }
        if result.success == false {
            throw QVACError.server(.cancelFailed, message: result.error)
        }
        return CancelAcknowledgement(cancelled: result.cancelled)
    }

    internal static func makeCancelRequest(_ operation: CancelOperation) -> CancelRequest {
        switch operation {
        case .request(let requestId, let clearCache):
            return CancelRequest(
                operation: "request",
                clearCache: clearCache,
                requestId: requestId
            )
        case .broad(let modelId, let kind):
            return CancelRequest(
                operation: "broad",
                kind: kind,
                modelId: modelId
            )
        }
    }
}
