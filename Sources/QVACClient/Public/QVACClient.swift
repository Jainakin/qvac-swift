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
/// logging system. Visible in Xcode's console (when the app is launched from
/// Xcode), in `Console.app` (when filtering by subsystem `io.qvac.client`),
/// and in `log stream --predicate 'subsystem == "io.qvac.client"'`.
///
/// Used as the default logger in ``QVACClient/init(configuration:runtimeContext:config:initHandshakeTimeout:logger:)``
/// so users get init / handshake / frame visibility out of the box without
/// having to plumb anything. Pass `nil` to opt out.
public struct QVACOSLogger: BareRPCLogger {
    public static let `default` = QVACOSLogger()
    private let logger = Logger(subsystem: "io.qvac.client", category: "rpc")
    public init() {}
    public func log(_ level: BareRPCLogLevel, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info:  logger.info("\(message, privacy: .public)")
        case .warn:  logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }
}

/// Internal sentinel used by the init-handshake timeout path. Never surfaced
/// to callers — translated to a ``QVACError/transport(reason:underlying:)`` in
/// ``QVACClient/init(configuration:runtimeContext:config:initHandshakeTimeout:logger:)``.
struct QVACInitHandshakeTimeout: Error {}

/// `BareRPCLogger` that drops every line — used when the caller opts out by
/// passing `nil` for the `logger` parameter so the call sites can still emit
/// `log.log(...)` without checking for nil at every site.
struct NoOpRPCLogger: BareRPCLogger {
    func log(_ level: BareRPCLogLevel, _ message: String) {}
}

public actor QVACClient {

    /// Configuration for spawning the worker. Use one of the static `.macOS(…)` /
    /// `.iOS(…)` factories rather than constructing this manually.
    public enum Configuration: @unchecked Sendable {
        #if os(macOS)
        case macOSSubprocess(UDSTransportConfiguration)
        #endif
        #if os(iOS)
        case iOSWorklet(BareIPCTransport.Configuration)
        #endif

        /// macOS convenience — auto-discovers `bare` on $PATH and uses the SDK's worker.js
        /// from the supplied node_modules dir.
        public static func macOS(
            nodeModulesDir: URL,
            bareExecutable: URL? = nil,
            initTimeout: TimeInterval = 30.0,
            environmentOverlay: [String: String] = [:]
        ) throws -> Configuration {
            #if os(macOS)
            let workerScript = nodeModulesDir
                .appendingPathComponent("@qvac/sdk/dist/server/worker.js")
            let bare = bareExecutable ?? Self.discoverBareOnPath()
                ?? URL(fileURLWithPath: "/opt/homebrew/bin/bare")
            return .macOSSubprocess(UDSTransportConfiguration(
                bareExecutable: bare,
                workerScript: workerScript,
                workingDirectory: nodeModulesDir.deletingLastPathComponent(),
                initTimeout: initTimeout,
                environmentOverlay: environmentOverlay
            ))
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
            memoryLimit: UInt = 0
        ) -> Configuration {
            return .iOSWorklet(BareIPCTransport.Configuration(
                workletSource: workletBundleData,
                workletEntryName: entryName,
                arguments: arguments,
                memoryLimit: memoryLimit
            ))
        }

        /// iOS convenience that auto-loads the bundled `worker.mobile.bundle` resource
        /// shipped with the SPM package (regenerated at release time —
        /// `@qvac/cli bundle sdk` → `tools/bundle/unwrap-bundle.mjs`).
        /// Use this when you depend on QVACClient via SPM and want the default plugin set.
        public static func iOSWithBundledResource(
            entryName: String = "/worker.bundle",
            arguments: [String] = Self.defaultWorkletArguments(),
            memoryLimit: UInt = 0
        ) throws -> Configuration {
            guard let url = Bundle.module.url(forResource: "worker.mobile", withExtension: "bundle") else {
                throw QVACError.transport(reason: "worker.mobile.bundle not bundled in QVACClient resources")
            }
            let data = try Data(contentsOf: url)
            return iOS(
                workletBundleData: data,
                entryName: entryName,
                arguments: arguments,
                memoryLimit: memoryLimit
            )
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
            let configJSON = #"{"HOME_DIR":"\#(home.path)"}"#
            return ["qvac-swift-client", "worker.js", configJSON]
        }
        #endif

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
    private var commandCounter: UInt64 = 0
    private var initialized = false
    private var closed = false

    // MARK: - Lifecycle

    /// Construct + spawn the worker + perform the `__init_config` handshake.
    /// Equivalent to JS's lazy-init-on-first-call pattern, but explicit.
    ///
    /// The init handshake is bounded by ``initHandshakeTimeout`` (default 60s).
    /// If the worker bundle crashes during startup or runs in direct mode (no
    /// RPC handler), the call throws ``QVACError/transport(reason:underlying:)``
    /// rather than hanging.
    public init(
        configuration: Configuration,
        runtimeContext: QVACRuntimeContext? = .current,
        config: JSONValue? = nil,
        initHandshakeTimeout: Duration = .seconds(60),
        logger: BareRPCLogger? = QVACOSLogger.default
    ) async throws {
        let log = logger ?? NoOpRPCLogger()
        log.log(.info, "QVACClient init: starting transport")

        switch configuration {
        #if os(macOS)
        case .macOSSubprocess(let cfg):
            do {
                self.transport = try await UnixDomainSocketTransport.connect(cfg)
            } catch let e as UnixDomainSocketTransport.SpawnError {
                log.log(.error, "QVACClient init: macOS subprocess connect failed — \(e)")
                throw QVACError.transport(reason: e.description, underlying: e)
            }
        #endif
        #if os(iOS)
        case .iOSWorklet(let cfg):
            do {
                log.log(.info, "QVACClient init: spawning BareKit worklet (entry=\(cfg.workletEntryName), argv=\(cfg.arguments))")
                self.transport = try BareIPCTransport.connect(cfg)
                log.log(.info, "QVACClient init: BareKit worklet + IPC ready")
            } catch let e as BareIPCTransport.Error {
                log.log(.error, "QVACClient init: BareIPCTransport.connect failed — \(e)")
                throw QVACError.transport(reason: e.description, underlying: e)
            }
        #endif
        }
        self.rpc = BareRPCClient(transport: transport, logger: logger)

        log.log(.info, "QVACClient init: sending __init_config (timeout=\(initHandshakeTimeout))")
        do {
            try await withInitTimeout(initHandshakeTimeout) {
                try await QVACHandshake.sendInitConfig(
                    on: self.rpc, config: config, runtimeContext: runtimeContext
                )
            }
            log.log(.info, "QVACClient init: handshake OK, client ready")
            self.initialized = true
        } catch let e as QVACInitConfigFailed {
            log.log(.error, "QVACClient init: __init_config rejected by worker — \(e.description)")
            await rpc.close()
            throw QVACError.transport(reason: e.description, underlying: e)
        } catch is QVACInitHandshakeTimeout {
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
            throw error
        }
    }

    private func withInitTimeout<T: Sendable>(
        _ timeout: Duration,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw QVACInitHandshakeTimeout()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Tear down the connection and (on macOS) terminate the worker subprocess.
    /// Idempotent. Auto-invoked from `unloadModel` when the last model unloads
    /// (matches the JS client's auto-close behavior).
    public func close() async {
        if closed { return }
        closed = true
        await rpc.close()
    }

    deinit {
        if !closed { Task { [rpc] in await rpc.close() } }
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
        decoding _: Response.Type = Response.self
    ) async throws -> Response {
        try await assertOpen()
        let payload = try encode(request)
        let respData: Data?
        do {
            respData = try await rpc.send(command: nextCommand(), data: payload)
        } catch let e as BareRPCError {
            throw QVACError.fromWire(code: Int(e.errno), message: e.message)
        } catch {
            throw QVACError.transport(reason: "send failed", underlying: error)
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
        decoding _: Response.Type = Response.self
    ) async throws -> AsyncThrowingStream<Response, Error> {
        try await assertOpen()
        let payload = try encode(request)
        let cmd = nextCommand()
        let rawStream = try await rpc.stream(command: cmd, data: payload)
        return AsyncThrowingStream<Response, Error> { continuation in
            let task = Task<Void, Never> {
                do {
                    var buffer = Data()
                    for try await chunk in rawStream.chunks {
                        buffer.append(chunk)
                        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer[buffer.startIndex..<newlineIndex]
                            buffer.removeSubrange(buffer.startIndex...newlineIndex)
                            if lineData.isEmpty { continue }
                            do {
                                let decoded: Response = try Self.decodeOrThrowStatic(Response.self, from: Data(lineData))
                                continuation.yield(decoded)
                            } catch {
                                continuation.finish(throwing: error)
                                return
                            }
                        }
                    }
                    // Drain any residual line at EOF.
                    let trimmed = buffer.filter { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }
                    if !trimmed.isEmpty {
                        let decoded: Response = try Self.decodeOrThrowStatic(Response.self, from: buffer)
                        continuation.yield(decoded)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                rawStream.destroy()
            }
        }
    }

    /// Open a duplex session, encode + send the initial JSON request, return a session
    /// the caller can `write(_:)` audio bytes to and iterate for NDJSON responses.
    func duplexTyped<Response: Decodable & Sendable>(
        _ request: QVACRequest,
        decoding _: Response.Type = Response.self
    ) async throws -> QVACDuplexSession<Response> {
        try await assertOpen()
        let payload = try encode(request)
        let cmd = nextCommand()
        let raw = try await rpc.duplex(command: cmd, initialPayload: payload)
        return QVACDuplexSession(raw: raw)
    }

    /// Encode a `QVACRequest` into JSON wire bytes.
    private func encode(_ request: QVACRequest) throws -> Data {
        do {
            return try JSONEncoder.qvac.encode(request)
        } catch {
            throw QVACError.encoding("could not encode request: \(error)")
        }
    }

    /// Decode a JSON wire payload into `Response`, checking for the `type: "error"`
    /// pattern that server-side errors travel as.
    private func decodeOrThrow<R: Decodable>(_ type: R.Type, from data: Data) throws -> R {
        return try Self.decodeOrThrowStatic(type, from: data)
    }

    /// Static so streams (which run outside actor isolation) can also use it.
    static func decodeOrThrowStatic<R: Decodable>(_ type: R.Type, from data: Data) throws -> R {
        // First peek at the discriminator: if it's "error", surface as QVACError directly.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["type"] as? String == "error" {
            let code = (obj["code"] as? Int) ?? 0
            let message = obj["message"] as? String
            throw QVACError.fromWire(code: code, message: message)
        }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw QVACError.encoding("could not decode response: \(error)")
        }
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

// MARK: - Public duplex session wrapper

/// Bidirectional session for audio APIs (`transcribeStream`, `textToSpeechStream`).
///
/// The session is single-use: iterate `responses` exactly once. Writes can be interleaved
/// with reads — they go on different bare-rpc stream directions, so there's no contention.
public final class QVACDuplexSession<Response: Sendable & Decodable>: @unchecked Sendable {
    private let raw: BareRPCDuplexSession
    private var consumed = false
    private let lock = NSLock()

    init(raw: BareRPCDuplexSession) { self.raw = raw }

    /// Write a chunk of arbitrary binary data to the server. For audio APIs this is
    /// raw PCM/Opus/wav bytes.
    public func write(_ chunk: Data) async {
        await raw.write(chunk)
    }

    /// Signal end-of-stream on the client→server direction. The server will still emit
    /// any pending responses before terminating its side.
    public func end() async {
        await raw.end()
    }

    /// Hard-terminate the whole session.
    public func destroy() {
        raw.destroy()
    }

    /// Async sequence of decoded responses. Single-use.
    public var responses: AsyncThrowingStream<Response, Error> {
        lock.lock(); defer { lock.unlock() }
        precondition(!consumed, "QVACDuplexSession.responses can only be iterated once")
        consumed = true
        let rawSession = raw
        return AsyncThrowingStream<Response, Error> { continuation in
            let task = Task<Void, Never> {
                do {
                    var buffer = Data()
                    for try await chunk in rawSession.chunks {
                        buffer.append(chunk)
                        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer[buffer.startIndex..<newlineIndex]
                            buffer.removeSubrange(buffer.startIndex...newlineIndex)
                            if lineData.isEmpty { continue }
                            do {
                                let decoded: Response = try QVACClient.decodeOrThrowStatic(Response.self, from: Data(lineData))
                                continuation.yield(decoded)
                            } catch {
                                continuation.finish(throwing: error)
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                rawSession.destroy()
            }
        }
    }
}
