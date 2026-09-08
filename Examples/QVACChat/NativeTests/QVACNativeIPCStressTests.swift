import CryptoKit
import Darwin
import Foundation
import MachO
import XCTest
@testable import QVACClient

/// App-hosted evidence for the patched BareKit implementation. Unlike the
/// package transport tests, these cases create real BareWorklet and BareIPC
/// objects inside an iOS application process. The worklets use inline source;
/// no model, network access, or third-party test fixture is involved.
final class QVACNativeIPCStressTests: XCTestCase {
    private static let mebibyte = 1_024 * 1_024
    private static let transportBufferBytes = 32 * mebibyte
    private static let requiredPatchLevel = "qvac-bare-kit-2.3.0-ipc-hardening-1"
    private static let expectedEchoDigest =
        "c9e77904d4198fb6b70b6556e0d0229139bd3aa7dee40d70b8c7cddfdd1d537f"

    func testPatchedNativeIPCBackpressureOrderingAndConcurrentCloseRace() async throws {
        let payload = Self.patternData(byteCount: 16 * Self.mebibyte)
        let expectedDigest = Self.sha256Hex(payload)
        let chunkDigests = stride(from: 0, to: payload.count, by: 64 * 1_024).map {
            Self.sha256Hex(payload[$0..<min($0 + 64 * 1_024, payload.count)])
        }
        XCTAssertEqual(expectedDigest, Self.expectedEchoDigest)
        XCTAssertEqual(
            Set(chunkDigests).count,
            chunkDigests.count,
            "each native-write chunk must carry a distinct absolute-position pattern"
        )
        let echoTransport = try Self.makePatchedTransport(
            source: Self.delayedEchoWorkletSource(
                delayMilliseconds: 750,
                expectedByteCount: payload.count
            )
        )
        let echoStream = echoTransport.inboundStream()
        let writer = Task { try await echoTransport.write(payload) }

        do {
            let echoed = try await Self.withTimeout(
                seconds: 45,
                operation: { try await Self.collectExactly(payload.count, from: echoStream) }
            )
            try await Self.withTimeout(seconds: 15, operation: { try await writer.value })

            XCTAssertEqual(echoed.count, payload.count)
            XCTAssertEqual(echoed, payload, "native IPC changed byte order or contents")
            XCTAssertEqual(Self.sha256Hex(echoed), expectedDigest)
            let nativeWriteWouldBlockCount = echoTransport.__testNativeWriteWouldBlockCount()
            XCTAssertGreaterThan(
                nativeWriteWouldBlockCount,
                0,
                "the delayed 16 MiB echo did not exercise native write backpressure"
            )
        } catch {
            writer.cancel()
            _ = try? await Self.withTimeout(seconds: 5) { await echoTransport.close() }
            throw error
        }
        try await Self.withTimeout(seconds: 5) { await echoTransport.close() }

        // Repeatedly close while the native readable callback is draining an
        // indefinitely writable peer. This is the ownership/race boundary fixed
        // by the r2 BareKit patch, not the Swift BackendProbe seam.
        var raceObservedBytes: [Int] = []
        var raceCloseReadOverlaps: [Bool] = []
        var raceObservedFollowerCloseWaiterCounts: [Int] = []
        for iteration in 0..<12 {
            let transport = try Self.makePatchedTransport(
                source: Self.continuousPatternWorkletSource()
            )
            let overlapBarrier = NativeReadableDrainBarrier()
            transport.__testInstallNativeReadableDrainBarrier {
                overlapBarrier.holdInsideNativeReadableDrain()
            }
            let stream = transport.inboundStream()
            let (firstChunks, firstChunkContinuation) = AsyncStream.makeStream(
                of: Data.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            let reader = Task { () throws -> Int in
                var received = 0
                do {
                    for try await chunk in stream {
                        received += chunk.count
                        if received == chunk.count {
                            firstChunkContinuation.yield(chunk)
                            firstChunkContinuation.finish()
                        }
                    }
                    firstChunkContinuation.finish()
                    return received
                } catch {
                    firstChunkContinuation.finish()
                    throw error
                }
            }
            do {
                try await Self.withTimeout(seconds: 5) {
                    try await transport.write(Data([0x01]))
                }
                try await Self.withTimeout(seconds: 10) {
                    await overlapBarrier.waitUntilEntered()
                }
                let first = try await Self.withTimeout(seconds: 10) {
                    var iterator = firstChunks.makeAsyncIterator()
                    return await iterator.next()
                }
                XCTAssertNotNil(first, "iteration \(iteration) ended before native traffic arrived")
                XCTAssertFalse(first?.isEmpty ?? true, "iteration \(iteration) produced an empty chunk")

                let ownerClose = Task { await transport.close() }
                do {
                    let overlap = try await Self.withTimeout(seconds: 5) {
                        try await Self.waitForNativeCloseReadOverlap(in: transport)
                    }
                    let followerCloses = (0..<15).map { _ in
                        Task { await transport.close() }
                    }
                    let followerWaiterCount: Int
                    do {
                        followerWaiterCount = try await Self.withTimeout(seconds: 5) {
                            try await Self.waitForRegisteredCloseFollowers(
                                in: transport,
                                expectedCount: followerCloses.count
                            )
                        }
                    } catch {
                        overlapBarrier.release()
                        ownerClose.cancel()
                        for followerClose in followerCloses { followerClose.cancel() }
                        _ = try? await Self.withTimeout(seconds: 5) {
                            await ownerClose.value
                            for followerClose in followerCloses { await followerClose.value }
                        }
                        throw error
                    }
                    raceCloseReadOverlaps.append(overlap)
                    raceObservedFollowerCloseWaiterCounts.append(followerWaiterCount)
                    overlapBarrier.release()
                    try await Self.withTimeout(seconds: 10) {
                        await ownerClose.value
                        for followerClose in followerCloses { await followerClose.value }
                    }
                } catch {
                    overlapBarrier.release()
                    ownerClose.cancel()
                    throw error
                }

                let received = try await Self.withTimeout(seconds: 5) {
                    try await reader.value
                }
                XCTAssertGreaterThan(received, 0, "iteration \(iteration) observed no native bytes")
                raceObservedBytes.append(received)
            } catch {
                overlapBarrier.release()
                reader.cancel()
                firstChunkContinuation.finish()
                _ = try? await Self.withTimeout(seconds: 5) { await transport.close() }
                throw error
            }
        }
        XCTAssertEqual(raceCloseReadOverlaps, Array(repeating: true, count: 12))
        XCTAssertEqual(
            raceObservedFollowerCloseWaiterCounts,
            Array(repeating: 15, count: 12),
            "every iteration must register all follower closes before releasing the native read"
        )
        add(Self.jsonAttachment(
            TrafficEvidence(
                transferredBytes: payload.count,
                sha256: expectedDigest,
                chunkBytes: 64 * 1_024,
                uniqueChunkCount: Set(chunkDigests).count,
                nativeWriteWouldBlockCount: echoTransport.__testNativeWriteWouldBlockCount(),
                raceIterations: raceObservedBytes.count,
                concurrentCloseCallersPerIteration: 16,
                raceObservedBytes: raceObservedBytes,
                raceCloseReadOverlaps: raceCloseReadOverlaps,
                raceObservedFollowerCloseWaiterCounts: raceObservedFollowerCloseWaiterCounts
            ),
            named: "native-ipc-backpressure-race.json"
        ))
    }

    func testPatchedNativeIPCSustainedMemoryPlateausAfterWarmup() async throws {
        if Self.isThreadSanitizerLoaded {
            throw XCTSkip(
                "phys_footprint is intentionally gated only in an unsanitized app-hosted process"
            )
        }

        let phaseBytes = 32 * Self.mebibyte
        let totalBytes = 256 * Self.mebibyte
        let creditedBatchBytes = Self.mebibyte
        let transport = try Self.makePatchedTransport(
            source: Self.creditedPatternWorkletSource(
                batchByteCount: creditedBatchBytes,
                totalByteCount: totalBytes
            ),
            maximumInboundBufferedBytes: 4 * Self.mebibyte
        )
        let stream = transport.inboundStream()

        let result: MemoryRun
        do {
            result = try await Self.withTimeout(seconds: 120) {
                try await Self.consumePatternedTraffic(
                    byteCount: totalBytes,
                    phaseBytes: phaseBytes,
                    creditedBatchBytes: creditedBatchBytes,
                    from: stream,
                    transport: transport
                )
            }
        } catch {
            _ = try? await Self.withTimeout(seconds: 5) { await transport.close() }
            throw error
        }
        try await Self.withTimeout(seconds: 5) { await transport.close() }

        let expectedDigest = Self.repeatedPatternDigest(byteCount: totalBytes)
        XCTAssertEqual(result.byteCount, totalBytes)
        XCTAssertEqual(result.digest, expectedDigest)
        XCTAssertEqual(result.samples.count, totalBytes / phaseBytes)

        // The first 32 MiB is allocator/JIT warm-up. Across the subsequent
        // 224 MiB, permit substantial platform noise while rejecting growth
        // compatible with retaining every NSData returned by BareIPC.read.
        let warmFootprint = try XCTUnwrap(result.samples.first?.physicalFootprintBytes)
        let finalFootprint = try XCTUnwrap(result.samples.last?.physicalFootprintBytes)
        let retainedGrowth = max(0, Int64(finalFootprint) - Int64(warmFootprint))
        let maximumRetainedGrowth = Int64(32 * Self.mebibyte)
        let slope = Self.leastSquaresFootprintSlope(result.samples)

        let evidence = MemoryEvidence(
            transferredBytes: result.byteCount,
            sha256: result.digest,
            warmupBytes: phaseBytes,
            maximumRetainedGrowthBytes: maximumRetainedGrowth,
            observedRetainedGrowthBytes: retainedGrowth,
            maximumFootprintBytesPerTransferredByte: 0.05,
            observedFootprintBytesPerTransferredByte: slope,
            samples: result.samples
        )
        add(Self.jsonAttachment(evidence, named: "native-ipc-memory-plateau.json"))

        XCTAssertLessThanOrEqual(
            retainedGrowth,
            maximumRetainedGrowth,
            "post-warm-up phys_footprint did not plateau; evidence: \(evidence.description)"
        )
        XCTAssertLessThanOrEqual(
            slope,
            0.05,
            "post-warm-up phys_footprint slope indicates retained native reads; evidence: \(evidence.description)"
        )
    }
}

private extension QVACNativeIPCStressTests {
    struct Timeout: Error, CustomStringConvertible {
        let seconds: Int
        var description: String { "native IPC operation exceeded \(seconds) seconds" }
    }

    struct NativeStressFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    struct FootprintFailure: Error, CustomStringConvertible {
        let status: kern_return_t
        var description: String { "task_info(TASK_VM_INFO) failed with status \(status)" }
    }

    struct MemorySample: Codable, Sendable {
        let transferredBytes: Int
        let physicalFootprintBytes: UInt64
    }

    struct MemoryRun: Sendable {
        let byteCount: Int
        let digest: String
        let samples: [MemorySample]
    }

    struct TrafficEvidence: Codable {
        let transferredBytes: Int
        let sha256: String
        let chunkBytes: Int
        let uniqueChunkCount: Int
        let nativeWriteWouldBlockCount: Int
        let raceIterations: Int
        let concurrentCloseCallersPerIteration: Int
        let raceObservedBytes: [Int]
        let raceCloseReadOverlaps: [Bool]
        let raceObservedFollowerCloseWaiterCounts: [Int]
    }

    struct MemoryEvidence: Codable, CustomStringConvertible {
        let transferredBytes: Int
        let sha256: String
        let warmupBytes: Int
        let maximumRetainedGrowthBytes: Int64
        let observedRetainedGrowthBytes: Int64
        let maximumFootprintBytesPerTransferredByte: Double
        let observedFootprintBytesPerTransferredByte: Double
        let samples: [MemorySample]

        var description: String {
            "growth=\(observedRetainedGrowthBytes)/\(maximumRetainedGrowthBytes), "
                + "slope=\(observedFootprintBytesPerTransferredByte)/"
                + "\(maximumFootprintBytesPerTransferredByte), samples=\(samples)"
        }
    }

    final class TimeoutGate<Value: Sendable>: @unchecked Sendable {
        enum Winner {
            case operation
            case timer
        }

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var operationTask: Task<Void, Never>?
        private var timerWorkItem: DispatchWorkItem?
        private var settled = false

        init(_ continuation: CheckedContinuation<Value, Error>) {
            self.continuation = continuation
        }

        func installOperation(_ task: Task<Void, Never>) {
            install(task, as: .operation)
        }

        func installTimer(_ workItem: DispatchWorkItem) {
            let cancel = lock.withLock { () -> Bool in
                guard !settled else { return true }
                timerWorkItem = workItem
                return false
            }
            if cancel { workItem.cancel() }
        }

        @discardableResult
        func resolve(_ result: Result<Value, Error>, winner: Winner) -> Bool {
            let resolution: (
                CheckedContinuation<Value, Error>?,
                Task<Void, Never>?,
                DispatchWorkItem?
            ) =
                lock.withLock {
                    guard !settled else { return (nil, nil, nil) }
                    settled = true
                    let continuation = self.continuation
                    self.continuation = nil
                    let operationToCancel: Task<Void, Never>?
                    let timerToCancel: DispatchWorkItem?
                    switch winner {
                    case .operation:
                        operationToCancel = nil
                        timerToCancel = timerWorkItem
                    case .timer:
                        operationToCancel = operationTask
                        timerToCancel = nil
                    }
                    operationTask = nil
                    timerWorkItem = nil
                    return (continuation, operationToCancel, timerToCancel)
                }
            resolution.1?.cancel()
            resolution.2?.cancel()
            resolution.0?.resume(with: result)
            return resolution.0 != nil
        }

        private func install(_ task: Task<Void, Never>, as winner: Winner) {
            let cancel = lock.withLock { () -> Bool in
                guard !settled else { return true }
                switch winner {
                case .operation:
                    operationTask = task
                case .timer:
                    preconditionFailure("timer work items use installTimer(_:)")
                }
                return false
            }
            if cancel { task.cancel() }
        }
    }

    final class NativeReadableDrainBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private var entered = false
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []

        func holdInsideNativeReadableDrain() {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                precondition(!entered, "native readable-drain barrier is single-use")
                entered = true
                defer { entryWaiters.removeAll() }
                return entryWaiters
            }
            for waiter in waiters { waiter.resume() }
            releaseSemaphore.wait()
        }

        func waitUntilEntered() async {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock { () -> Bool in
                    if entered { return true }
                    entryWaiters.append(continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }

        func release() {
            let shouldSignal = lock.withLock { () -> Bool in
                guard !released else { return false }
                released = true
                return true
            }
            if shouldSignal { releaseSemaphore.signal() }
        }
    }

    static func makePatchedTransport(
        source: String,
        maximumInboundBufferedBytes: Int = transportBufferBytes
    ) throws -> BareIPCTransport {
        guard let process = dlopen(nil, RTLD_NOW) else {
            throw NativeStressFailure(message: "dlopen failed while checking BareKit r2")
        }
        defer { dlclose(process) }
        guard let patchSymbol = dlsym(process, "BareKitQVACPatchLevel"),
              let patchObject = patchSymbol.load(as: UnsafeRawPointer?.self) else {
            throw NativeStressFailure(
                message: "native stress tests require the staged BareKit r2 patch marker"
            )
        }
        let patchLevel = Unmanaged<NSString>.fromOpaque(patchObject).takeUnretainedValue() as String
        guard patchLevel == requiredPatchLevel else {
            throw NativeStressFailure(
                message: "native stress tests require BareKit patch \(requiredPatchLevel); got \(patchLevel)"
            )
        }
        return try BareIPCTransport.connect(
            .init(
                workletSource: Data(source.utf8),
                workletEntryName: "/qvac-native-stress.js",
                memoryLimit: 64 * UInt(mebibyte)
            ),
            maximumInboundBufferedBytes: maximumInboundBufferedBytes
        )
    }

    static func delayedEchoWorkletSource(
        delayMilliseconds: Int,
        expectedByteCount: Int
    ) -> String {
        """
        const ipc = BareKit.IPC
        let received = 0
        setTimeout(() => {
          ipc.on('data', (data) => {
            received += data.length
            if (received > \(expectedByteCount)) {
              ipc.destroy(new Error('received more bytes than expected'))
              return
            }
            if (!ipc.write(data)) {
              ipc.pause()
              ipc.once('drain', () => ipc.resume())
            }
            if (received === \(expectedByteCount)) ipc.end()
          })
        }, \(delayMilliseconds))
        """
    }

    static func continuousPatternWorkletSource() -> String {
        """
        const ipc = BareKit.IPC
        const chunk = Buffer.allocUnsafe(65536)
        for (let i = 0; i < chunk.length; i++) chunk[i] = i & 255
        let started = false
        function pump() {
          while (ipc.write(chunk)) {}
          ipc.once('drain', pump)
        }
        ipc.on('data', (command) => {
          if (started || command.length === 0) return
          started = true
          pump()
        })
        """
    }

    static func waitForNativeCloseReadOverlap(
        in transport: BareIPCTransport
    ) async throws -> Bool {
        while true {
            let state = transport.__testNativeCloseReadOverlapState()
            if state.closeStarted {
                guard state.activeNativeReadableDrains > 0 else {
                    throw NativeStressFailure(
                        message: "close began after the native readable drain had already exited"
                    )
                }
                return true
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static func waitForRegisteredCloseFollowers(
        in transport: BareIPCTransport,
        expectedCount: Int
    ) async throws -> Int {
        precondition(expectedCount > 0)
        while true {
            let closeState = transport.__testCloseState()
            let overlapState = transport.__testNativeCloseReadOverlapState()
            if closeState.closed {
                guard !closeState.finished else {
                    throw NativeStressFailure(
                        message: "owned close finished before follower closes registered"
                    )
                }
                guard overlapState.activeNativeReadableDrains > 0 else {
                    throw NativeStressFailure(
                        message: "native readable drain exited before follower closes registered"
                    )
                }
                guard closeState.waiterCount <= expectedCount else {
                    throw NativeStressFailure(
                        message: "registered more than \(expectedCount) follower closes"
                    )
                }
                if closeState.waiterCount == expectedCount { return closeState.waiterCount }
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static func creditedPatternWorkletSource(
        batchByteCount: Int,
        totalByteCount: Int
    ) -> String {
        """
        const ipc = BareKit.IPC
        const chunkSize = 65536
        const chunks = Array.from(
          { length: \(batchByteCount) / chunkSize },
          () => {
            const chunk = Buffer.allocUnsafe(chunkSize)
            for (let i = 0; i < chunk.length; i++) chunk[i] = i & 255
            return chunk
          }
        )
        let credits = 0
        let chunkIndex = 0
        let generated = 0
        let wordIndex = 0
        let sending = false
        ipc.on('data', (commands) => {
          credits += commands.length
          startBatch()
        })
        function startBatch() {
          if (sending || credits === 0) return
          credits--
          chunkIndex = 0
          for (const chunk of chunks) {
            for (let offset = 0; offset < chunk.length; offset += 4) {
              chunk.writeUInt32LE(wordIndex, offset)
              wordIndex++
            }
          }
          sending = true
          pump()
        }
        function pump() {
          while (chunkIndex !== chunks.length) {
            const chunk = chunks[chunkIndex++]
            generated += chunk.length
            if (!ipc.write(chunk)) {
              ipc.once('drain', pump)
              return
            }
          }
          sending = false
          if (generated === \(totalByteCount)) {
            ipc.end()
            return
          }
          startBatch()
        }
        """
    }

    static func patternData(byteCount: Int) -> Data {
        precondition(byteCount.isMultiple(of: MemoryLayout<UInt32>.size))
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { rawBuffer in
            let words = rawBuffer.bindMemory(to: UInt32.self)
            for index in words.indices {
                words[index] = UInt32(index).littleEndian
            }
        }
        return data
    }

    static func collectExactly(
        _ expectedBytes: Int,
        from stream: AsyncThrowingStream<Data, Error>
    ) async throws -> Data {
        var result = Data()
        result.reserveCapacity(expectedBytes)
        for try await chunk in stream {
            guard chunk.count <= expectedBytes - result.count else {
                throw NativeStressFailure(
                    message: "native echo sent more than \(expectedBytes) bytes"
                )
            }
            result.append(chunk)
        }
        guard result.count == expectedBytes else {
            throw BareRPCProtocolError(
                "native echo ended after \(result.count) of \(expectedBytes) expected bytes"
            )
        }
        return result
    }

    static func consumePatternedTraffic(
        byteCount: Int,
        phaseBytes: Int,
        creditedBatchBytes: Int,
        from stream: AsyncThrowingStream<Data, Error>,
        transport: BareIPCTransport
    ) async throws -> MemoryRun {
        precondition(
            byteCount > 0
                && byteCount.isMultiple(of: phaseBytes)
                && phaseBytes.isMultiple(of: creditedBatchBytes)
        )
        var received = 0
        var nextSample = phaseBytes
        var nextCredit = creditedBatchBytes
        var hasher = SHA256()
        var samples: [MemorySample] = []
        samples.reserveCapacity(byteCount / phaseBytes)
        try await transport.write(Data([0x01]))

        for try await chunk in stream {
            guard chunk.count <= byteCount - received else {
                throw BareRPCProtocolError("native memory worklet sent more than \(byteCount) bytes")
            }
            hasher.update(data: chunk)
            received += chunk.count

            while received >= nextSample {
                samples.append(.init(
                    transferredBytes: nextSample,
                    physicalFootprintBytes: try currentPhysicalFootprint()
                ))
                nextSample += phaseBytes
            }

            if received == nextCredit, received < byteCount {
                try await transport.write(Data([0x01]))
                nextCredit += creditedBatchBytes
            } else if received > nextCredit {
                throw NativeStressFailure(
                    message: "credited worklet crossed its \(nextCredit)-byte boundary"
                )
            }
        }
        guard received == byteCount else {
            throw BareRPCProtocolError(
                "native memory worklet ended after \(received) of \(byteCount) expected bytes"
            )
        }
        return MemoryRun(
            byteCount: received,
            digest: hex(hasher.finalize()),
            samples: samples
        )
    }

    static func repeatedPatternDigest(byteCount: Int) -> String {
        let chunkByteCount = 64 * 1_024
        precondition(byteCount.isMultiple(of: chunkByteCount))
        var chunk = patternData(byteCount: chunkByteCount)
        var hasher = SHA256()
        var wordIndex: UInt32 = 0
        for _ in 0..<(byteCount / chunkByteCount) {
            chunk.withUnsafeMutableBytes { rawBuffer in
                let words = rawBuffer.bindMemory(to: UInt32.self)
                for index in words.indices {
                    words[index] = wordIndex.littleEndian
                    wordIndex += 1
                }
            }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func currentPhysicalFootprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw FootprintFailure(status: status) }
        return info.phys_footprint
    }

    static func leastSquaresFootprintSlope(_ samples: [MemorySample]) -> Double {
        guard samples.count >= 2 else { return .infinity }
        let originX = Double(samples[0].transferredBytes)
        let originY = Double(samples[0].physicalFootprintBytes)
        let points = samples.map {
            (
                x: Double($0.transferredBytes) - originX,
                y: Double($0.physicalFootprintBytes) - originY
            )
        }
        let meanX = points.reduce(0) { $0 + $1.x } / Double(points.count)
        let meanY = points.reduce(0) { $0 + $1.y } / Double(points.count)
        let numerator = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
        let denominator = points.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
        return max(0, numerator / denominator)
    }

    static var isThreadSanitizerLoaded: Bool {
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            if String(cString: name).contains("libclang_rt.tsan") { return true }
        }
        return false
    }

    static func jsonAttachment<T: Encodable>(_ value: T, named name: String) -> XCTAttachment {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("evidence encoding failed".utf8)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }

    static func withTimeout<T: Sendable>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = TimeoutGate<T>(continuation)
            let operationTask = Task {
                do {
                    gate.resolve(.success(try await operation()), winner: .operation)
                } catch {
                    gate.resolve(.failure(error), winner: .operation)
                }
            }
            gate.installOperation(operationTask)
            let timerWorkItem = DispatchWorkItem {
                gate.resolve(.failure(Timeout(seconds: seconds)), winner: .timer)
            }
            gate.installTimer(timerWorkItem)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .seconds(seconds),
                execute: timerWorkItem
            )
        }
    }
}
