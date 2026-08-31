// QVACClient — the public entry point.
//
// Owns:
//   • A `BareRPCClient` (the codec + multiplexer)
//   • A `BareTransport` (UDS subprocess on macOS, BareKit worklet on iOS)
//   • A monotonic command-id counter (matches QVAC's JS commandCounter)
//
// API methods live in extensions in this same directory, one file per RPC group.
// All methods are isolated to this actor; cross-actor calls are explicit `await`s.

import Foundation
import OSLog

/// Default `BareRPCLogger` implementation that forwards to Apple's unified
/// logging system. Dynamic text is marked private so worker diagnostics and
/// application identifiers are redacted from persisted production logs. It
/// remains available to developers with appropriate log-data access.
///
/// Used as the default logger in
/// ``QVACClient/init(configuration:runtimeContext:config:initHandshakeTimeout:maximumWireMessageBytes:maximumBufferedStreamBytes:profilingMetadataHandler:logger:)``
/// so users get init / handshake / frame visibility out of the box without
/// having to plumb anything. Pass `nil` to opt out.
// `OSLog.Logger` is safe to share across concurrency domains, but the macOS 14
// SDK overlay used by GitHub's arm64 runner predates its `Sendable` annotation.
// Keep the unchecked boundary confined to this immutable adapter instead of
// weakening concurrency checking for the entire OSLog module.
public struct QVACOSLogger: BareRPCLogger, @unchecked Sendable {
    public static let `default` = QVACOSLogger()
    private let logger = Logger(subsystem: "io.qvac.client", category: "rpc")
    public init() {}
    public func log(_ level: BareRPCLogLevel, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .private)")
        case .info:  logger.info("\(message, privacy: .private)")
        case .warn:  logger.warning("\(message, privacy: .private)")
        case .error: logger.error("\(message, privacy: .private)")
        }
    }
}

/// `BareRPCLogger` that drops every line — used when the caller opts out by
/// passing `nil` for the `logger` parameter so the call sites can still emit
/// `log.log(...)` without checking for nil at every site.
struct NoOpRPCLogger: BareRPCLogger {
    func log(_ level: BareRPCLogLevel, _ message: String) {}
}

public actor QVACClient {

    /// Default ceiling for one length-prefixed bare-rpc body and one NDJSON record.
    /// QVAC 0.17 video/upscale results may exceed the historical 64 MiB limit, so
    /// production clients default to 256 MiB while retaining a finite memory bound.
    public static let defaultMaximumWireMessageBytes = 256 * 1024 * 1024

    /// Opaque worker configuration. Construct it with `macOS`, `iOS`, or
    /// `iOSWithBundledResource`; transport implementation types are not part
    /// of the SDK's public API.
    public struct Configuration: Sendable {
        enum Storage: Sendable {
        #if os(macOS)
            case macOSSubprocess(UDSTransportConfiguration)
        #endif
        #if os(iOS)
            case iOSWorklet(BareIPCTransport.Configuration)
        #endif
            /// Internal-only seam that still exercises the production initializer,
            /// including handshake validation and public error normalization.
            case testing(BareTransport, shutdownBeforeClose: Bool)
        }

        let storage: Storage

        init(storage: Storage) {
            self.storage = storage
        }

        #if os(macOS)
        /// Internal construction seam for transport integration tests.
        static func macOSSubprocess(_ configuration: UDSTransportConfiguration) -> Self {
            Self(storage: .macOSSubprocess(configuration))
        }
        #endif

        #if os(iOS)
        /// Internal construction seam for BareKit integration tests.
        static func iOSWorklet(_ configuration: BareIPCTransport.Configuration) -> Self {
            Self(storage: .iOSWorklet(configuration))
        }
        #endif

        static func testing(
            _ transport: BareTransport,
            shutdownBeforeClose: Bool = false
        ) -> Self {
            Self(storage: .testing(transport, shutdownBeforeClose: shutdownBeforeClose))
        }

        /// macOS convenience — prefers the lockfile-local
        /// `node_modules/bare-runtime/bin/bare`, then falls back to discovering
        /// `bare` on `$PATH`, and uses the SDK's `worker.js` from the supplied
        /// node_modules directory. Pass `homeDirectory` to isolate the worker's
        /// `HOME_DIR`; otherwise it uses the current process home directory.
        public static func macOS(
            nodeModulesDir: URL,
            bareExecutable: URL? = nil,
            initTimeout: TimeInterval = 30.0,
            environmentOverlay: [String: String] = [:],
            homeDirectory: URL? = nil
        ) throws -> Configuration {
            #if os(macOS)
            let workerScript = nodeModulesDir
                .appendingPathComponent("@qvac/sdk/dist/server/worker.js")
            let packageBare = nodeModulesDir
                .appendingPathComponent("bare-runtime/bin/bare")
            let localBare = FileManager.default.isExecutableFile(atPath: packageBare.path)
                ? packageBare
                : nil
            let bare = bareExecutable ?? localBare ?? Self.discoverBareOnPath()
                ?? URL(fileURLWithPath: "/opt/homebrew/bin/bare")
            return Self(storage: .macOSSubprocess(UDSTransportConfiguration(
                bareExecutable: bare,
                workerScript: workerScript,
                workingDirectory: nodeModulesDir.deletingLastPathComponent(),
                initTimeout: initTimeout,
                environmentOverlay: environmentOverlay,
                homeDir: homeDirectory?.standardizedFileURL.path
            )))
            #else
            throw QVACError.transport(reason: "macOS configuration unavailable on this platform")
            #endif
        }

        #if os(iOS)
        /// iOS convenience — point at a raw bare-bundle binary (`worker.mobile.bundle`)
        /// shipped as a bundle resource. The file is the unwrapped output of
        /// `@qvac/cli bundle sdk`, processed by `tools/bundle/unwrap-bundle.mjs` so
        /// `bare-module`'s `.bundle` extension handler can parse it directly.
        ///
        /// `arguments` MUST follow the QVAC worker's argv contract — see
        /// `defaultWorkletArguments(homeDirectory:)` for the canonical shape. The
        /// worker decides RPC vs direct mode by JSON-parsing `argv[2]`; an empty
        /// argv (or argv[2] that isn't valid JSON) silently runs it in direct
        /// mode, which skips RPC setup entirely and causes every Swift call to
        /// hang on the `__init_config` reply.
        public static func iOS(
            workletBundleData: Data,
            entryName: String = "/worker.bundle",
            arguments: [String] = Self.defaultWorkletArguments(),
            memoryLimit: UInt = 0,
            assets: String? = nil
        ) -> Configuration {
            return Self(storage: .iOSWorklet(BareIPCTransport.Configuration(
                workletSource: workletBundleData,
                workletEntryName: entryName,
                arguments: arguments,
                memoryLimit: memoryLimit,
                assets: assets
            )))
        }

        /// iOS convenience that auto-loads the bundled `worker.mobile.bundle` resource
        /// shipped with the SPM package (regenerated at release time —
        /// `@qvac/cli bundle sdk` → `tools/bundle/unwrap-bundle.mjs`).
        /// Use this when you depend on QVACClient via SPM and want the default plugin set.
        public static func iOSWithBundledResource(
            entryName: String = "/worker.bundle",
            arguments: [String] = Self.defaultWorkletArguments(),
            memoryLimit: UInt = 0,
            assets: String? = nil
        ) throws -> Configuration {
            guard let url = Bundle.module.url(forResource: "worker.mobile", withExtension: "bundle") else {
                throw QVACError.transport(reason: "worker.mobile.bundle not bundled in QVACClient resources")
            }
            let data = try Self.readWorkletBundleData(from: url)
            return iOS(
                workletBundleData: data,
                entryName: entryName,
                arguments: arguments,
                memoryLimit: memoryLimit,
                assets: assets
            )
        }
        #endif

        /// Shared read boundary so a public factory never leaks Foundation's
        /// Cocoa-domain file errors through the SDK error surface.
        static func readWorkletBundleData(from url: URL) throws -> Data {
            do {
                return try Data(contentsOf: url)
            } catch {
                throw QVACError.transport(
                    reason: "could not read bundled worker.mobile.bundle",
                    underlying: error
                )
            }
        }

        /// Build the canonical `process.argv` for the QVAC worker.
        ///
        /// Mirrors `@qvac/sdk`'s expo-rpc-client.js worker-start call:
        ///   - argv[0] = "qvac-swift-client" (placeholder, also picked up as a
        ///     HOME_DIR fallback in BareKit mode)
        ///   - argv[1] = "worker.js" (script-name placeholder)
        ///   - argv[2] = JSON config; setting *any* valid JSON here flips the
        ///     worker into RPC mode (see `@qvac/sdk/dist/server/env.js`).
        ///
        /// `HOME_DIR` is set to the iOS app's Documents directory by default —
        /// the worker uses it for model cache, hyperdb workspaces, log files,
        /// etc. Pass an explicit URL to override.
        public static func defaultWorkletArguments(homeDirectory: URL? = nil) -> [String] {
            let home = homeDirectory
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let encoded = try? JSONSerialization.data(
                withJSONObject: ["HOME_DIR": home.path],
                options: [.sortedKeys]
            )
            // A String-to-String dictionary is always valid JSON. Keep the factory
            // nonthrowing while ensuring even quotes, backslashes, and control
            // characters in a caller-supplied URL are escaped correctly.
            let configJSON = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return ["qvac-swift-client", "worker.js", configJSON]
        }

        #if os(macOS)
        private static func discoverBareOnPath() -> URL? {
            // 1. Common static install locations.
            let staticCandidates = [
                "/opt/homebrew/bin/bare",
                "/usr/local/bin/bare",
            ]
            for c in staticCandidates where FileManager.default.fileExists(atPath: c) {
                return URL(fileURLWithPath: c)
            }
            // 2. nvm: scan ~/.nvm/versions/node/v*/bin/bare. nvm uses versioned dirs
            //    (v22.0.0), not a `current` symlink, so we pick the alphabetically last
            //    (highest semver-ish version that has `bare` installed).
            let nvmRoot = "\(NSHomeDirectory())/.nvm/versions/node"
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
                for v in versions.sorted(by: >) {
                    let p = "\(nvmRoot)/\(v)/bin/bare"
                    if FileManager.default.fileExists(atPath: p) {
                        return URL(fileURLWithPath: p)
                    }
                }
            }
            // 3. $PATH search via `/usr/bin/which`. Keeps us honest if the user has bare
            //    installed somewhere unusual (e.g. asdf, mise, custom $HOME bin).
            if let viaWhich = whichBare() {
                return viaWhich
            }
            return nil
        }

        private static func whichBare() -> URL? {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            proc.arguments = ["bare"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do { try proc.run() } catch { return nil }
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let data = try? pipe.fileHandleForReading.readToEnd(),
                  let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty,
                  FileManager.default.fileExists(atPath: path)
            else { return nil }
            return URL(fileURLWithPath: path)
        }
        #endif
    }

    // MARK: - State

    let transport: BareTransport
    let rpc: BareRPCClient
    let maximumWireMessageBytes: Int
    let maximumBufferedStreamBytes: Int
    private let shutdownBeforeClose: Bool
    private let shutdownTimeout: Duration
    private let logger: BareRPCLogger?
    private let profilingMetadataHandler: (@Sendable (QVACProfilingMetadata) -> Void)?
    private var commandCounter: UInt64 = 0
    private var initialized = false
    private var closed = false
    private var closeTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Internal transport-injection seam for deterministic contract and lifecycle tests.
    /// Production callers must use the public configuration initializer so worker
    /// startup and the `__init_config` handshake cannot be bypassed.
    init(
        testing transport: BareTransport,
        maximumWireMessageBytes: Int = QVACClient.defaultMaximumWireMessageBytes,
        maximumBufferedStreamBytes: Int? = nil,
        shutdownBeforeClose: Bool = false,
        shutdownTimeout: Duration = .seconds(10),
        profilingMetadataHandler: (@Sendable (QVACProfilingMetadata) -> Void)? = nil,
        logger: BareRPCLogger? = nil
    ) {
        precondition(maximumWireMessageBytes > 0 && maximumWireMessageBytes <= Int(UInt32.max))
        let bufferLimit = maximumBufferedStreamBytes ?? maximumWireMessageBytes
        precondition(bufferLimit > 0 && bufferLimit <= Int(UInt32.max))
        self.transport = transport
        self.maximumWireMessageBytes = maximumWireMessageBytes
        self.maximumBufferedStreamBytes = bufferLimit
        self.shutdownBeforeClose = shutdownBeforeClose
        self.shutdownTimeout = shutdownTimeout
        self.logger = logger
        self.profilingMetadataHandler = profilingMetadataHandler
        self.rpc = BareRPCClient(
            validatedTransport: transport,
            maximumWireMessageBytes: maximumWireMessageBytes,
            maximumBufferedStreamBytes: bufferLimit,
            logger: logger
        )
        self.initialized = true
    }

    /// Construct + spawn the worker + perform the `__init_config` handshake.
    /// Equivalent to JS's lazy-init-on-first-call pattern, but explicit.
    ///
    /// The init handshake is bounded by `initHandshakeTimeout` (default 60s).
    /// If the worker bundle crashes during startup or runs in direct mode (no
    /// RPC handler), the call throws ``QVACError/transport(reason:underlying:)``
    /// rather than hanging.
    public init(
        configuration: Configuration,
        runtimeContext: QVACRuntimeContext? = .current,
        config: JSONValue? = nil,
        initHandshakeTimeout: Duration = .seconds(60),
        maximumWireMessageBytes: Int = QVACClient.defaultMaximumWireMessageBytes,
        maximumBufferedStreamBytes: Int? = nil,
        profilingMetadataHandler: (@Sendable (QVACProfilingMetadata) -> Void)? = nil,
        logger: BareRPCLogger? = QVACOSLogger.default
    ) async throws {
        guard initHandshakeTimeout > .zero else {
            throw QVACError.invalidArgument("initHandshakeTimeout must be greater than zero")
        }
        guard maximumWireMessageBytes > 0,
              maximumWireMessageBytes <= Int(UInt32.max) else {
            throw QVACError.invalidArgument(
                "maximumWireMessageBytes must be between 1 and UInt32.max"
            )
        }
        let bufferLimit = maximumBufferedStreamBytes ?? maximumWireMessageBytes
        guard bufferLimit > 0, bufferLimit <= Int(UInt32.max) else {
            throw QVACError.invalidArgument(
                "maximumBufferedStreamBytes must be between 1 and UInt32.max"
            )
        }
        self.maximumWireMessageBytes = maximumWireMessageBytes
        self.maximumBufferedStreamBytes = bufferLimit
        self.logger = logger
        self.profilingMetadataHandler = profilingMetadataHandler
        let log = logger ?? NoOpRPCLogger()
        log.log(.info, "QVACClient init: starting transport")

        switch configuration.storage {
        #if os(macOS)
        case .macOSSubprocess(let cfg):
            self.shutdownBeforeClose = false
            do {
                self.transport = try await UnixDomainSocketTransport.connect(
                    cfg,
                    maximumInboundBufferedBytes: maximumWireMessageBytes + 4
                )
            } catch let e as UnixDomainSocketTransport.SpawnError {
                log.log(.error, "QVACClient init: macOS subprocess connect failed — \(e)")
                throw QVACError.transport(reason: e.description, underlying: e)
            }
        #endif
        #if os(iOS)
        case .iOSWorklet(let cfg):
            self.shutdownBeforeClose = true
            do {
                log.log(
                    .info,
                    "QVACClient init: spawning BareKit worklet "
                        + "(entry=\(cfg.workletEntryName), argumentCount=\(cfg.arguments.count))"
                )
                self.transport = try BareIPCTransport.connect(
                    cfg,
                    maximumInboundBufferedBytes: maximumWireMessageBytes + 4
                )
                log.log(.info, "QVACClient init: BareKit worklet + IPC ready")
            } catch let e as BareIPCTransport.Error {
                log.log(.error, "QVACClient init: BareIPCTransport.connect failed — \(e)")
                throw QVACError.transport(reason: e.description, underlying: e)
            }
        #endif
        case .testing(let transport, let shutdownBeforeClose):
            self.shutdownBeforeClose = shutdownBeforeClose
            self.transport = transport
        }
        self.shutdownTimeout = .seconds(10)
        self.rpc = BareRPCClient(
            validatedTransport: transport,
            maximumWireMessageBytes: maximumWireMessageBytes,
            maximumBufferedStreamBytes: bufferLimit,
            logger: logger
        )

        log.log(.info, "QVACClient init: sending __init_config (timeout=\(initHandshakeTimeout))")
        do {
            try await QVACHandshake.sendInitConfig(
                on: self.rpc,
                config: config,
                runtimeContext: runtimeContext,
                timeout: initHandshakeTimeout
            )
            log.log(.info, "QVACClient init: handshake OK, client ready")
            self.initialized = true
        } catch is CancellationError {
            log.log(.info, "QVACClient init: __init_config cancelled")
            await rpc.close()
            throw CancellationError()
        } catch let e as QVACInitConfigFailed {
            log.log(.error, "QVACClient init: __init_config rejected by worker — \(e.description)")
            await rpc.close()
            throw QVACError.transport(reason: e.description, underlying: e)
        } catch is BareRPCRequestTimeout {
            let msg = "worker did not reply to __init_config within \(initHandshakeTimeout). " +
                "Most likely the worker bundle crashed during startup, or `arguments` " +
                "did not include a valid JSON config in argv[2] (which silently runs the " +
                "worker in direct mode — see Configuration.defaultWorkletArguments)."
            log.log(.error, "QVACClient init: \(msg)")
            await rpc.close()
            throw QVACError.transport(reason: msg)
        } catch {
            log.log(.error, "QVACClient init: handshake failed — \(error)")
            await rpc.close()
            throw Self.publicRPCError(error, operation: "__init_config")
        }
    }

    /// Tear down the connection and (on macOS) terminate the worker subprocess.
    /// Idempotent. The 0.17 lifecycle is explicit: unloading the last model does not
    /// close the client.
    public func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        closed = true
        let rpc = self.rpc
        let shouldShutdown = shutdownBeforeClose
        let shutdownTimeout = self.shutdownTimeout
        let logger = self.logger
        let task = Task {
            if shouldShutdown {
                do {
                    try await QVACHandshake.sendShutdown(on: rpc, timeout: shutdownTimeout)
                } catch {
                    logger?.log(.warn, "QVACClient close: bounded __shutdown__ failed; forcing transport close")
                }
            }
            await rpc.close()
        }
        closeTask = task
        await task.value
    }

    deinit {
        if !closed {
            let rpc = self.rpc
            let shouldShutdown = shutdownBeforeClose
            let shutdownTimeout = self.shutdownTimeout
            Task {
                if shouldShutdown {
                    try? await QVACHandshake.sendShutdown(on: rpc, timeout: shutdownTimeout)
                }
                await rpc.close()
            }
        }
    }

    // MARK: - Internal helpers used by every API method

    /// Allocate the next monotonic command id (mirrors JS `getNextCommandId`).
    func nextCommand() -> UInt64 {
        commandCounter = commandCounter &+ 1
        if commandCounter == 0 { commandCounter = 1 } // skip the events channel
        return commandCounter
    }

    /// Encode `request`, send as single-shot RPC, decode `Response`.
    /// Maps wire-level errors (`type: "error"` payloads) to `QVACError`.
    func sendTyped<Response: Decodable & Sendable>(
        _ request: QVACRequest,
        decoding _: Response.Type = Response.self,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> Response {
        try await assertOpen()
        let timeout = try Self.validatedRPCOptions(rpcOptions)
        let payload = try encode(request, rpcOptions: rpcOptions)
        let respData: Data?
        do {
            respData = try await rpc.send(command: nextCommand(), data: payload, timeout: timeout)
        } catch {
            throw Self.publicRPCError(error, operation: request.discriminator)
        }
        guard let data = respData else {
            throw QVACError.protocolViolation("empty reply")
        }
        return try decodeOrThrow(Response.self, from: data)
    }

    /// Send `request`, stream NDJSON chunks back, decode each line into `Response`.
    /// Caller iterates the returned stream — errors propagate via throw.
    func streamTyped<Response: Decodable & Sendable>(
        _ request: QVACRequest,
        decoding _: Response.Type = Response.self,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<Response> {
        try await assertOpen()
        let timeout = try Self.validatedRPCOptions(rpcOptions)
        let payload = try encode(request, rpcOptions: rpcOptions)
        let cmd = nextCommand()
        let operation = request.discriminator
        let rawStream: BareRPCResponseStream
        do {
            rawStream = try await rpc.stream(command: cmd, data: payload, timeout: timeout)
        } catch {
            throw Self.publicRPCError(error, operation: operation)
        }
        let driver = QVACTypedStreamDriver<Response>(
            raw: rawStream,
            operation: operation,
            maximumRecordBytes: maximumWireMessageBytes,
            profilingMetadataHandler: profilingMetadataHandler
        )
        return QVACResponseStream<Response>(unfolding: {
            try await driver.next()
        }, onTermination: {
            rawStream.destroy()
        })
    }

    /// Open a duplex session, encode + send the initial JSON request, return a session
    /// the caller can `write(_:)` audio bytes to and iterate for NDJSON responses.
    func duplexTyped<Response: Decodable & Sendable>(
        _ request: QVACRequest,
        decoding _: Response.Type = Response.self,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACDuplexSession<Response> {
        try await assertOpen()
        let timeout = try Self.validatedRPCOptions(rpcOptions)
        let payload = try encode(request, rpcOptions: rpcOptions)
        let cmd = nextCommand()
        do {
            let raw = try await rpc.duplex(command: cmd, initialPayload: payload, timeout: timeout)
            return QVACDuplexSession(
                raw: raw,
                operation: request.discriminator,
                maximumRecordBytes: maximumWireMessageBytes,
                profilingMetadataHandler: profilingMetadataHandler
            )
        } catch {
            throw Self.publicRPCError(error, operation: request.discriminator)
        }
    }

    /// Encode a `QVACRequest` into JSON wire bytes.
    private func encode(_ request: QVACRequest, rpcOptions: QVACRPCOptions) throws -> Data {
        do {
            let payload = try JSONEncoder.qvac.encode(request)
            return try Self.applyingProfilingOptions(rpcOptions.profiling, to: payload)
        } catch {
            throw QVACError.encoding("could not encode request: \(error)")
        }
    }

    /// Decode a JSON wire payload into `Response`, checking for the `type: "error"`
    /// pattern that server-side errors travel as.
    private func decodeOrThrow<R: Decodable>(_ type: R.Type, from data: Data) throws -> R {
        return try Self.decodeOrThrowStatic(
            type,
            from: data,
            profilingMetadataHandler: profilingMetadataHandler
        )
    }

    /// Static so streams (which run outside actor isolation) can also use it.
    static func decodeOrThrowStatic<R: Decodable>(
        _ type: R.Type,
        from data: Data,
        profilingMetadataHandler: (@Sendable (QVACProfilingMetadata) -> Void)? = nil
    ) throws -> R {
        let data = try strippingProfilingMetadata(
            from: data,
            handler: profilingMetadataHandler
        )

        // Generated union-based paths decode the discriminated response once
        // and surface its error case directly. The former JSONSerialization
        // discriminator probe parsed every successful response twice, adding
        // avoidable latency to each streamed response record/frame. Keep the
        // generic fallback below for concrete response decoders.
        if type == QVACResponse.self {
            do {
                let response = try JSONDecoder().decode(QVACResponse.self, from: data)
                if case .error(let envelope) = response {
                    let code = try checkedWireErrorCode(envelope.code)
                    throw QVACError.fromWire(code: code, message: envelope.message)
                }
                guard let typed = response as? R else {
                    throw QVACError.protocolViolation(
                        "decoded QVACResponse could not be returned as the requested type"
                    )
                }
                return typed
            } catch let error as QVACError {
                throw error
            } catch {
                // Preserve the stronger malformed-error diagnostic without
                // charging successful responses for a second JSON parse.
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["type"] as? String == "error" {
                    throw QVACError.protocolViolation("malformed error response: \(error)")
                }
                throw QVACError.encoding("could not decode response: \(error)")
            }
        }

        // First peek at the discriminator: if it's "error", surface as QVACError directly.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["type"] as? String == "error" {
            do {
                let envelope = try JSONDecoder().decode(ErrorResponse.self, from: data)
                let code = try checkedWireErrorCode(envelope.code)
                throw QVACError.fromWire(code: code, message: envelope.message)
            } catch let error as QVACError {
                throw error
            } catch {
                throw QVACError.protocolViolation("malformed error response: \(error)")
            }
        }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw QVACError.encoding("could not decode response: \(error)")
        }
    }

    /// Decode one already-framed NDJSON record, dropping only the SDK's explicit
    /// metadata-only profiling trailer.
    static func decodeStreamRecord<R: Decodable>(
        _ type: R.Type,
        from data: Data,
        profilingMetadataHandler: (@Sendable (QVACProfilingMetadata) -> Void)? = nil
    ) throws -> R? {
        if QVACNDJSONDecoder.isProfilingTrailer(data) {
            _ = try strippingProfilingMetadata(from: data, handler: profilingMetadataHandler)
            return nil
        }
        return try decodeOrThrowStatic(
            type,
            from: data,
            profilingMetadataHandler: profilingMetadataHandler
        )
    }

    static func validatedTimeout(_ timeout: Duration?) throws -> Duration? {
        guard let timeout else { return nil }
        guard timeout >= .milliseconds(100) else {
            throw QVACError.invalidArgument("rpcOptions.timeout must be at least 100 milliseconds")
        }
        return timeout
    }

    static func validatedRPCOptions(_ options: QVACRPCOptions) throws -> Duration? {
        if let healthCheckTimeout = options.healthCheckTimeout,
           healthCheckTimeout < .milliseconds(100) {
            throw QVACError.invalidArgument(
                "rpcOptions.healthCheckTimeout must be at least 100 milliseconds"
            )
        }
        return try validatedTimeout(options.timeout)
    }

    /// Mirrors 0.17's request envelope. Swift has no process-global profiler,
    /// so an omitted `enabled` value follows the upstream disabled default.
    static func applyingProfilingOptions(
        _ options: QVACProfilingOptions?,
        to payload: Data
    ) throws -> Data {
        guard let options, let enabled = options.enabled else { return payload }
        guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw QVACError.encoding("profiling metadata requires a top-level JSON object request")
        }
        var metadata: [String: Any] = ["enabled": enabled]
        if enabled {
            metadata["id"] = UUID().uuidString.lowercased()
            metadata["includeServer"] = options.includeServerBreakdown ?? false
            metadata["includeResources"] = options.includeResourceGauges ?? false
        }
        object["__profiling"] = metadata
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Captures and removes the response envelope before generated Codable types
    /// see it. Unknown/malformed metadata is still stripped, matching 0.17's
    /// `stripProfilingMeta`; only a valid object is delivered to the hook.
    private static func strippingProfilingMetadata(
        from payload: Data,
        handler: (@Sendable (QVACProfilingMetadata) -> Void)?
    ) throws -> Data {
        guard payload.range(of: Data("\"__profiling\"".utf8)) != nil else {
            return payload
        }

        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: payload)
        } catch {
            throw QVACError.encoding("could not decode response JSON: \(error)")
        }
        guard var object = decoded as? [String: Any],
              let rawMetadata = object.removeValue(forKey: "__profiling") else {
            return payload
        }

        if let handler,
           JSONSerialization.isValidJSONObject(rawMetadata),
           let metadataData = try? JSONSerialization.data(
               withJSONObject: rawMetadata,
               options: [.sortedKeys, .fragmentsAllowed]
           ),
           let value = try? JSONDecoder().decode(JSONValue.self, from: metadataData),
           case .object = value {
            handler(QVACProfilingMetadata(value: value))
        }
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw QVACError.encoding("could not strip response profiling metadata: \(error)")
        }
    }

    static func publicRPCError(_ error: Error, operation: String) -> Error {
        if let qvac = error as? QVACError { return qvac }
        if error is CancellationError { return CancellationError() }
        if let timeout = error as? BareRPCRequestTimeout {
            return QVACError.requestTimedOut(operation: operation, after: timeout.timeout)
        }
        if let overflow = error as? BareRPCStreamBufferOverflow {
            return QVACError.streamBufferOverflow(
                operation: operation,
                maximumBytes: overflow.maximumBufferedBytes,
                attemptedBytes: overflow.attemptedBufferedBytes
            )
        }
        if let invalid = error as? BareRPCInvalidArgument {
            return QVACError.invalidArgument(invalid.reason)
        }
        if let protocolError = error as? BareRPCProtocolError {
            return QVACError.protocolViolation(protocolError.reason)
        }
        if error is BareRPCCodecError || error is CompactEncodingError {
            return QVACError.protocolViolation("malformed bare-rpc frame: \(error)")
        }
        if let ndjson = error as? QVACNDJSONError {
            return QVACError.encoding(ndjson.description)
        }
        if error is DecodingError || error is EncodingError {
            return QVACError.encoding("could not encode or decode JSON: \(error)")
        }
        if let remote = error as? BareRPCError {
            return QVACError.fromWire(code: Int(remote.errno), message: remote.message)
        }
        return QVACError.transport(reason: "\(operation) RPC failed", underlying: error)
    }

    private func assertOpen() async throws {
        if closed {
            throw QVACError.transport(reason: "client is closed")
        }
        if !initialized {
            throw QVACError.protocolViolation("client not initialized")
        }
    }
}

/// Pull-driven typed decoder. It does not create a second eager producer, so the
/// raw byte budget remains authoritative all the way to the public consumer even
/// when that consumer is slow.
private actor QVACTypedStreamDriver<Response: Sendable & Decodable> {
    private final class IteratorBox: @unchecked Sendable {
        var iterator: AsyncThrowingStream<Data, Error>.Iterator

        init(_ stream: AsyncThrowingStream<Data, Error>) {
            self.iterator = stream.makeAsyncIterator()
        }

        func next() async throws -> Data? {
            try await iterator.next()
        }
    }

    private let raw: BareRPCResponseStream
    private let operation: String
    private let profilingMetadataHandler: (@Sendable (QVACProfilingMetadata) -> Void)?
    private let iterator: IteratorBox
    private var decoder: QVACNDJSONDecoder
    private var reachedEOF = false
    private var isReading = false

    init(
        raw: BareRPCResponseStream,
        operation: String,
        maximumRecordBytes: Int,
        profilingMetadataHandler: (@Sendable (QVACProfilingMetadata) -> Void)?
    ) {
        self.raw = raw
        self.operation = operation
        self.profilingMetadataHandler = profilingMetadataHandler
        self.iterator = IteratorBox(raw.chunks)
        self.decoder = QVACNDJSONDecoder(maximumRecordBytes: maximumRecordBytes)
    }

    func next() async throws -> Response? {
        guard !isReading else {
            throw QVACError.protocolViolation(
                "response stream does not support concurrent next() calls"
            )
        }
        isReading = true
        defer { isReading = false }
        return try await withTaskCancellationHandler(operation: { () async throws -> Response? in
            do {
                while true {
                    if let record = try decoder.nextRecord(finalizing: reachedEOF) {
                        if let value: Response = try QVACClient.decodeStreamRecord(
                            Response.self,
                            from: record,
                            profilingMetadataHandler: profilingMetadataHandler
                        ) {
                            return value
                        }
                        continue
                    }
                    if reachedEOF { return nil }

                    if let chunk = try await iterator.next() {
                        decoder.receive(chunk)
                    } else {
                        reachedEOF = true
                    }
                }
            } catch {
                throw QVACClient.publicRPCError(error, operation: operation)
            }
        }, onCancel: {
            self.raw.destroy()
        })
    }

    deinit { raw.destroy() }
}

// MARK: - Public duplex session wrapper

/// Bidirectional session for audio APIs (`transcribeStream`, `textToSpeechStream`).
///
/// The session is single-use: iterate `responses` exactly once. Writes can be interleaved
/// with reads — they go on different bare-rpc stream directions, so there's no contention.
public final class QVACDuplexSession<Response: Sendable & Decodable>: @unchecked Sendable {
    private let raw: BareRPCDuplexSession
    private let operation: String
    private let maximumRecordBytes: Int
    private let profilingMetadataHandler: (@Sendable (QVACProfilingMetadata) -> Void)?
    private var consumed = false
    private let lock = NSLock()

    init(
        raw: BareRPCDuplexSession,
        operation: String,
        maximumRecordBytes: Int = QVACClient.defaultMaximumWireMessageBytes,
        profilingMetadataHandler: (@Sendable (QVACProfilingMetadata) -> Void)? = nil
    ) {
        self.raw = raw
        self.operation = operation
        self.maximumRecordBytes = maximumRecordBytes
        self.profilingMetadataHandler = profilingMetadataHandler
    }

    /// Write a chunk of arbitrary binary data to the server. For audio APIs this is
    /// raw PCM/Opus/wav bytes.
    public func write(_ chunk: Data) async throws {
        do {
            try await raw.write(chunk)
        } catch {
            throw QVACClient.publicRPCError(error, operation: operation)
        }
    }

    /// Signal end-of-stream on the client→server direction. The server will still emit
    /// any pending responses before terminating its side.
    public func end() async throws {
        do {
            try await raw.end()
        } catch {
            throw QVACClient.publicRPCError(error, operation: operation)
        }
    }

    /// Hard-terminate the whole session.
    public func destroy() {
        raw.destroy()
    }

    /// Async sequence of decoded responses. Single-use.
    public var responses: QVACResponseStream<Response> {
        lock.lock(); defer { lock.unlock() }
        guard !consumed else {
            return QVACResponseStream(unfolding: {
                throw QVACError.protocolViolation(
                    "QVACDuplexSession.responses can only be iterated once"
                )
            }, onTermination: {})
        }
        consumed = true
        let rawSession = raw
        let operation = operation
        let driver = QVACTypedStreamDriver<Response>(
            raw: BareRPCResponseStream(
                chunks: rawSession.chunks,
                onCancel: { rawSession.destroy() }
            ),
            operation: operation,
            maximumRecordBytes: maximumRecordBytes,
            profilingMetadataHandler: profilingMetadataHandler
        )
        return QVACResponseStream<Response>(unfolding: {
            try await driver.next()
        }, onTermination: {
            rawSession.destroy()
        })
    }
}
