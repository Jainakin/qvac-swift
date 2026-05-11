// BareTransport — abstraction over the byte-level link between the Swift host
// and the Bare worker. Two concrete implementations exist:
//
//   • UnixDomainSocketTransport  — macOS: spawns `bare worker.js` and connects via UDS.
//   • BareIPCTransport           — iOS: wraps BareKit's `BareIPC` for the in-process worklet.
//
// The contract is intentionally narrow:
//   – inboundStream() yields server bytes as they arrive (any framing handled higher up).
//   – write(_:) sends bytes (caller-managed framing).
//   – close() tears down resources.
//
// All implementations are actors or actor-like (must be Sendable) and produce frames
// suitable for BareRPCClient.

import Foundation

public protocol BareTransport: Sendable {
    /// AsyncThrowingStream of raw inbound bytes from the worker. Terminates on EOF or error.
    func inboundStream() -> AsyncThrowingStream<Data, Error>
    /// Write bytes to the worker. Throws on disconnection.
    func write(_ data: Data) async throws
    /// Tear down the link. Idempotent.
    func close() async
}
