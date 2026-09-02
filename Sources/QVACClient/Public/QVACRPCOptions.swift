import Foundation

/// Per-call profiling controls from the QVAC 0.17 RPC schema.
public struct QVACProfilingOptions: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable, Codable {
        case summary
        case verbose
    }

    public var enabled: Bool?
    public var includeServerBreakdown: Bool?
    public var includeResourceGauges: Bool?
    /// Upstream uses this only for its in-process client profiler's retention.
    /// Swift delivers every captured server envelope to `profilingMetadataHandler`,
    /// so this value is accepted for schema parity but is not sent to the worker.
    public var mode: Mode?

    public init(
        enabled: Bool? = nil,
        includeServerBreakdown: Bool? = nil,
        includeResourceGauges: Bool? = nil,
        mode: Mode? = nil
    ) {
        self.enabled = enabled
        self.includeServerBreakdown = includeServerBreakdown
        self.includeResourceGauges = includeResourceGauges
        self.mode = mode
    }
}

/// Raw server profiling envelope captured from a unary response, stream record,
/// or profiling-only trailer. Register a handler on `QVACClient.init` to observe it.
public struct QVACProfilingMetadata: Sendable, Equatable {
    public let value: JSONValue

    public init(value: JSONValue) {
        self.value = value
    }
}

/// Transport-level behavior for one QVAC operation.
///
/// `timeout` follows the QVAC 0.17 RPC contract:
///
/// - request/reply calls use it as the deadline for the reply;
/// - server streams use it as an inactivity deadline, refreshed by each inbound
///   OPEN or DATA frame;
/// - duplex calls use it while opening the two stream directions. Once opened,
///   a duplex session is intentionally long-lived and has no total deadline.
///
/// Calls use ``defaultTimeout`` unless the caller supplies an operation-specific
/// value. Pass `nil` explicitly to disable the deadline for an intentionally
/// long-lived operation. Values below 100 milliseconds are rejected by the
/// public client, matching the upstream SDK schema.
public struct QVACRPCOptions: Sendable, Equatable {
    /// Default deadline used when an operation does not provide one.
    /// Streaming operations interpret this as an inactivity timeout, not as a
    /// limit on their total duration.
    public static let defaultTimeout: Duration = .seconds(60)

    public var timeout: Duration?
    /// Accepted for 0.17 schema parity. The local SDK path does not perform the
    /// delegated-connection health probe, so this is a validated no-op.
    public var healthCheckTimeout: Duration?
    /// Accepted for 0.17 schema parity. The local SDK path does not consult the
    /// JavaScript connection cache, so this is a no-op.
    public var forceNewConnection: Bool?
    public var profiling: QVACProfilingOptions?

    public init(
        timeout: Duration? = Self.defaultTimeout,
        healthCheckTimeout: Duration? = nil,
        forceNewConnection: Bool? = nil,
        profiling: QVACProfilingOptions? = nil
    ) {
        self.timeout = timeout
        self.healthCheckTimeout = healthCheckTimeout
        self.forceNewConnection = forceNewConnection
        self.profiling = profiling
    }
}
