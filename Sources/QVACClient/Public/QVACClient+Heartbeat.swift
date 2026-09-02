// Worker heartbeat.
//
// Single-shot RPC. Worker replies with `{type:"heartbeat", number: <uptime-seconds>}`.
// Used both as a health check ("is the worker alive?") and by callers who want
// round-trip latency telemetry (sample the time around the call).

import Foundation

public extension QVACClient {

    /// Returns the worker's current uptime in seconds (a free-running counter started
    /// when the worker process was launched).
    ///
    /// Throws on transport failure or if the worker is unreachable.
    /// On success guarantees the wire-level handshake is healthy.
    @discardableResult
    func heartbeat(
        delegate: JSONValue? = nil,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> HeartbeatResponse {
        let request = QVACRequest.heartbeat(HeartbeatRequest(delegate: delegate))
        let response: QVACResponse = try await sendTyped(request, rpcOptions: rpcOptions)
        guard case .heartbeat(let hb) = response else {
            throw QVACError.protocolViolation(
                "expected heartbeat response, got \(response.discriminator)"
            )
        }
        return hb
    }
}
