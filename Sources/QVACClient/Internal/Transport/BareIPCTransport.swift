// BareIPCTransport — iOS path.
//
// Wraps BareKit's `BareWorklet` + `BareIPC` Objective-C objects as a `BareTransport`.
// The Bare worker runs in-process as a libuv pthread inside the host iOS app
// (no subprocess on iOS — Apple forbids it). All IPC is over the socketpair that
// BareKit's `BareIPC` wraps under the hood; we never touch the fd directly.
//
// Tested end-to-end in Examples/BareKitProbeApp on iPhone 17 simulator
// (see docs/spike-validations.md Spike-E and QVAC-004f).

#if canImport(BareKit) && os(iOS)
import Foundation
import BareKit
import OSLog

private let _bareKitLogger = Logger(subsystem: "io.qvac.client", category: "barekit")

final class BareIPCTransport: BareTransport, @unchecked Sendable {

    enum ReadableDrainResult: Sendable, Equatable {
        case wouldBlock
        case peerEOF
        case inboundOverflow
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case workletInitFailed
        case ipcInitFailed
        case invalidConfiguration(String)
        case writeFailed(underlying: Swift.Error)

        var description: String {
            switch self {
            case .workletInitFailed: return "BareWorklet init returned nil"
            case .ipcInitFailed:     return "BareIPC init returned nil"
            case .invalidConfiguration(let reason): return "Invalid BareIPC configuration: \(reason)"
            case .writeFailed(let u): return "BareIPC.write failed: \(u)"
            }
        }
    }

    struct Configuration: Sendable {
        /// Inline raw bare-bundle binary for the worklet (length-prefix + JSON header + assets).
        /// Typical use: the QVAC `worker.mobile.bundle` resource shipped in `QVACClient.bundle`
        /// (produced by `tools/bundle/unwrap-bundle.mjs` from `qvac bundle sdk` output).
        /// NOTE: pass raw bundle bytes here, not a JS wrapper — bare-module's `.bundle`
        /// extension handler parses this verbatim and rejects JS source.
        var workletSource: Data
        /// Virtual file name used by the worklet's module loader for stack traces / require resolution.
        var workletEntryName: String
        /// Arguments passed as `process.argv` inside the worklet (mirrors QVAC's JSON-arg pattern).
        var arguments: [String]
        /// Optional memory ceiling (in bytes). 0 = use BareKit default.
        var memoryLimit: UInt = 0
        /// Optional path to a bundle of assets for the worklet to access.
        var assets: String?

        init(
            workletSource: Data,
            workletEntryName: String = "/worker.bundle",
            arguments: [String] = [],
            memoryLimit: UInt = 0,
            assets: String? = nil
        ) {
            self.workletSource = workletSource
            self.workletEntryName = workletEntryName
            self.arguments = arguments
            self.memoryLimit = memoryLimit
            self.assets = assets
        }
    }

    private let worklet: BareWorklet
    private let ipc: BareIPC
    private let inbound: BoundedTransportInboundChannel
    private var closed = false
    private var closeFinished = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    static func connect(
        _ config: Configuration,
        maximumInboundBufferedBytes: Int = BareRPCFrameReader.defaultMaxFrameSize + 4
    ) throws -> BareIPCTransport {
        guard maximumInboundBufferedBytes > 0 else {
            throw Error.invalidConfiguration("maximumInboundBufferedBytes must be greater than zero")
        }
        _bareKitLogger.info("BareIPCTransport.connect: building BareWorkletConfiguration")
        guard let configObj = BareWorkletConfiguration.default() else {
            _bareKitLogger.error("BareWorkletConfiguration.default() returned nil")
            throw Error.workletInitFailed
        }
        if config.memoryLimit > 0 { configObj.memoryLimit = config.memoryLimit }
        if let assets = config.assets { configObj.assets = assets }

        _bareKitLogger.info("BareIPCTransport.connect: allocating BareWorklet")
        guard let worklet = BareWorklet(configuration: configObj) else {
            _bareKitLogger.error("BareWorklet(configuration:) returned nil")
            throw Error.workletInitFailed
        }

        _bareKitLogger.info("BareIPCTransport.connect: starting worklet bundleBytes=\(config.workletSource.count, privacy: .public) argumentCount=\(config.arguments.count, privacy: .public)")
        worklet.start(config.workletEntryName, source: config.workletSource, arguments: config.arguments)
        _bareKitLogger.info("BareIPCTransport.connect: worklet.start returned (fire-and-forget); allocating IPC")

        guard let ipc = BareIPC(worklet: worklet) else {
            _bareKitLogger.error("BareIPC(worklet:) returned nil — terminating worklet")
            worklet.terminate()
            throw Error.ipcInitFailed
        }
        _bareKitLogger.info("BareIPCTransport.connect: IPC ready")
        return BareIPCTransport(
            worklet: worklet,
            ipc: ipc,
            maximumInboundBufferedBytes: maximumInboundBufferedBytes
        )
    }

    private init(worklet: BareWorklet, ipc: BareIPC, maximumInboundBufferedBytes: Int) {
        self.worklet = worklet
        self.ipc = ipc
        self.inbound = BoundedTransportInboundChannel(
            maximumBufferedBytes: maximumInboundBufferedBytes
        )
        self.inbound.setCancellationHandler { [weak self] in
            Task { [weak self] in await self?.close() }
        }
        // Install the readable callback right away. BareIPC fires it on its internal GCD
        // queue (`to.holepunch.bare.kit.ipc`) so we marshal back via the continuation,
        // which is thread-safe per AsyncThrowingStream contract.
        ipc.readable = { [weak self] ipcRef in
            guard let self = self else { return }
            // Drain everything available on this fire. BareIPC's synchronous API
            // distinguishes would-block (`nil`) from peer EOF (a successful,
            // non-nil zero-byte read). Treat EOF as terminal immediately so the
            // bare-rpc generation fails its waiters and a later API call can
            // reconnect instead of hanging on an apparently open worklet.
            let result = Self.drainReadable(
                read: { ipcRef.read() as Data? },
                onChunk: { self.inbound.yield($0) == nil },
                onEOF: {
                    // Stop poll delivery before publishing EOF. The bare-rpc
                    // feeder drains any chunks already queued above, observes
                    // the channel finish, and then owns transport/worklet close.
                    ipcRef.readable = nil
                    self.inbound.finish(discardingBuffered: false)
                }
            )
            if result == .inboundOverflow {
                Task { [weak self] in await self?.close() }
            }
        }
    }

    /// Drain one readable notification while preserving the three distinct native
    /// outcomes: bytes, would-block, and zero-byte peer EOF. Keeping this logic in a
    /// dependency-free seam lets the iOS test target prove response-before-EOF order
    /// without pretending BareKit always reports worklet self-exit as EOF.
    private static func drainReadable(
        read: () -> Data?,
        onChunk: (Data) -> Bool,
        onEOF: () -> Void
    ) -> ReadableDrainResult {
        while let chunk = read() {
            guard !chunk.isEmpty else {
                onEOF()
                return .peerEOF
            }
            guard onChunk(chunk) else { return .inboundOverflow }
        }
        return .wouldBlock
    }

    static func __testDrainReadable(
        read: () -> Data?,
        into channel: BoundedTransportInboundChannel
    ) -> ReadableDrainResult {
        drainReadable(
            read: read,
            onChunk: { channel.yield($0) == nil },
            onEOF: { channel.finish(discardingBuffered: false) }
        )
    }

    /// Single-use — see UnixDomainSocketTransport.inboundStream() for the same
    /// invariant. Calling twice would silently abandon the first continuation.
    func inboundStream() -> AsyncThrowingStream<Data, Swift.Error> {
        inbound.stream()
    }

    func write(_ data: Data) async throws {
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await ipc.write(data)
                try Task.checkCancellation()
            } onCancel: {
                Task { [weak self] in await self?.close() }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error {
            _bareKitLogger.error("BareIPC -> worker write failed")
            throw Error.writeFailed(underlying: error)
        }
    }

    func close() async {
        let ownsClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard ownsClose else {
            await waitForCloseCompletion()
            return
        }

        inbound.finish(discardingBuffered: true)
        ipc.close()
        worklet.terminate()
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            closeFinished = true
            defer { closeWaiters.removeAll() }
            return closeWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func waitForCloseCompletion() async {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Bool in
                if closeFinished { return true }
                closeWaiters.append(continuation)
                return false
            }
            if completed { continuation.resume() }
        }
    }
}

#endif
