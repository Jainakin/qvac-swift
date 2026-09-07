import Foundation
import XCTest
@testable import QVACClient

final class BareIPCTransportLifecycleTests: XCTestCase {
    func testConfigurationPreservesEveryNativeOption() {
        let source = Data([0x01, 0x02, 0x03])
        let configuration = BareIPCTransport.Configuration(
            workletSource: source,
            workletEntryName: "/custom-worker.bundle",
            arguments: ["host", "worker.js", #"{"HOME_DIR":"/tmp/qvac"}"#],
            memoryLimit: 512 * 1024 * 1024,
            assets: "/tmp/qvac-assets"
        )

        XCTAssertEqual(configuration.workletSource, source)
        XCTAssertEqual(configuration.workletEntryName, "/custom-worker.bundle")
        XCTAssertEqual(configuration.arguments, [
            "host",
            "worker.js",
            #"{"HOME_DIR":"/tmp/qvac"}"#,
        ])
        XCTAssertEqual(configuration.memoryLimit, 512 * 1024 * 1024)
        XCTAssertEqual(configuration.assets, "/tmp/qvac-assets")
    }

    func testErrorDescriptionsRetainActionableContext() {
        let underlying = MarkerError(message: "native channel unavailable")

        XCTAssertEqual(
            BareIPCTransport.Error.workletInitFailed.description,
            "BareWorklet init returned nil"
        )
        XCTAssertEqual(
            BareIPCTransport.Error.ipcInitFailed.description,
            "BareIPC init returned nil"
        )
        XCTAssertEqual(
            BareIPCTransport.Error.invalidConfiguration("buffer must be positive").description,
            "Invalid BareIPC configuration: buffer must be positive"
        )
        XCTAssertEqual(
            BareIPCTransport.Error.readFailed(underlying: underlying).description,
            "BareIPC.read failed: native channel unavailable"
        )
        XCTAssertEqual(
            BareIPCTransport.Error.writeFailedBecauseTransportClosed.description,
            "BareIPC.write failed: transport is closed"
        )
        XCTAssertEqual(
            BareIPCTransport.Error.writeQueueCapacityExceeded.description,
            "BareIPC.write failed: pending write queue capacity exceeded"
        )
        XCTAssertEqual(
            BareIPCTransport.Error.writeFailed(underlying: underlying).description,
            "BareIPC.write failed: native channel unavailable"
        )
    }

    func testConnectRejectsEveryNonpositiveInboundLimitBeforeNativeStartup() {
        let configuration = BareIPCTransport.Configuration(workletSource: Data())

        for limit in [0, -1, Int.min] {
            XCTAssertThrowsError(
                try BareIPCTransport.connect(
                    configuration,
                    maximumInboundBufferedBytes: limit
                )
            ) { error in
                guard case let BareIPCTransport.Error.invalidConfiguration(reason) = error else {
                    return XCTFail("expected invalidConfiguration, got \(error)")
                }
                XCTAssertEqual(
                    reason,
                    "maximumInboundBufferedBytes must be greater than zero"
                )
            }
        }
    }

    func testReadableCallbackDrainsChunksThenPublishesEOFInOrder() async throws {
        let first = Data([0x10, 0x11])
        let second = Data([0x20, 0x21, 0x22])
        let probe = BackendProbe(reads: [first, second, Data()])
        let retainedBytes = first.count + second.count
            + BoundedTransportInboundChannel.retainedValueOverheadBytes
        let transport = makeTransport(
            maximumInboundBufferedBytes: retainedBytes,
            probe: probe
        )
        let stream = transport.inboundStream()

        probe.fireReadable()

        var iterator = stream.makeAsyncIterator()
        let delivered = try await iterator.next()
        let terminal = try await iterator.next()
        XCTAssertEqual(delivered, first + second)
        XCTAssertNil(terminal)
        XCTAssertEqual(probe.readCount, 3)
        XCTAssertEqual(probe.clearReadableCount, 1)

        await transport.close()
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
    }

    func testReadableCallbackWouldBlockWithoutFinishingStream() async throws {
        let chunk = Data([0x42])
        let probe = BackendProbe(reads: [chunk, nil])
        let transport = makeTransport(
            maximumInboundBufferedBytes: chunk.count
                + BoundedTransportInboundChannel.retainedValueOverheadBytes,
            probe: probe
        )
        var iterator = transport.inboundStream().makeAsyncIterator()

        probe.fireReadable()

        let delivered = try await iterator.next()
        XCTAssertEqual(delivered, chunk)
        XCTAssertEqual(probe.readCount, 2)
        XCTAssertEqual(probe.clearReadableCount, 0)

        await transport.close()
        let terminal = try await iterator.next()
        XCTAssertNil(terminal)
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
    }

    func testReadableCallbackOverflowFailsStreamAndClosesBackend() async throws {
        let chunk = Data(repeating: 0x7f, count: 5)
        let attemptedBytes = chunk.count
            + BoundedTransportInboundChannel.retainedValueOverheadBytes
        let maximumBytes = attemptedBytes - 1
        let probe = BackendProbe(reads: [chunk])
        let transport = makeTransport(
            maximumInboundBufferedBytes: maximumBytes,
            probe: probe
        )
        var iterator = transport.inboundStream().makeAsyncIterator()

        probe.fireReadable()

        do {
            _ = try await iterator.next()
            XCTFail("expected the bounded inbound channel to reject the oversized read")
        } catch let error as BareTransportInboundBufferOverflow {
            XCTAssertEqual(error.maximumBufferedBytes, maximumBytes)
            XCTAssertEqual(error.attemptedBufferedBytes, attemptedBytes)
        } catch {
            XCTFail("expected BareTransportInboundBufferOverflow, got \(error)")
        }

        // Synchronize with the close task scheduled by the readable callback.
        await transport.close()
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
    }

    func testReadableCallbackFailurePropagatesAndClosesBackend() async throws {
        let nativeError = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        let probe = BackendProbe(onRead: { throw nativeError })
        let transport = makeTransport(probe: probe)
        var iterator = transport.inboundStream().makeAsyncIterator()

        probe.fireReadable()

        do {
            _ = try await iterator.next()
            XCTFail("expected the checked native read failure")
        } catch {
            let captured = error as NSError
            XCTAssertEqual(captured.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(captured.code, Int(EIO))
        }

        await transport.close()
        XCTAssertEqual(probe.readCount, 1)
        XCTAssertEqual(probe.clearReadableCount, 1)
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
    }

    func testWriteForwardsBytesExactlyOnce() async throws {
        let probe = BackendProbe()
        let transport = makeTransport(probe: probe)
        let payload = Data([0xde, 0xad, 0xbe, 0xef])

        try await transport.write(payload)

        XCTAssertEqual(probe.writes, [payload])
        await transport.close()
    }

    func testConcurrentWritesUseSingleNativeFIFO() async throws {
        let callbacks = WriteCallbackRecorder()
        let transport = BareIPCTransport.__testTransport(
            maximumInboundBufferedBytes: 64,
            write: { data in callbacks.write(data) }
        )
        let first = Task { try await transport.write(Data([0x01])) }
        try await waitUntil("the first native write to start") { callbacks.count == 1 }
        let second = Task { try await transport.write(Data([0x02])) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(callbacks.payloads, [Data([0x01])])
        callbacks.allowFirstWrite()
        try await first.value

        try await waitUntil("the queued native write to start") { callbacks.count == 2 }
        XCTAssertEqual(callbacks.payloads, [Data([0x01]), Data([0x02])])
        try await second.value
        await transport.close()
    }

    func testWritePumpHandlesWouldBlockAndPartialProgressWithoutCopyingWrongRange() async throws {
        let writer = ScriptedSyncWriter(results: [0, 2, 2])
        let transport = BareIPCTransport.__testTransport(
            maximumInboundBufferedBytes: 64,
            write: { writer.write($0) }
        )
        let storage = Data([0xff, 0x01, 0x02, 0x03, 0x04, 0xee])
        let payload = storage[1..<5]

        try await transport.write(payload)

        XCTAssertEqual(writer.offers, [
            Data([0x01, 0x02, 0x03, 0x04]),
            Data([0x01, 0x02, 0x03, 0x04]),
            Data([0x03, 0x04]),
        ])
        await transport.close()
    }

    func testInvalidNativeWriteCountFailsGenerationAndDoesNotAdvanceQueue() async {
        let writer = ScriptedSyncWriter(results: [Int.max])
        let transport = BareIPCTransport.__testTransport(
            maximumInboundBufferedBytes: 64,
            write: { writer.write($0) }
        )

        do {
            try await transport.write(Data([0x01]))
            XCTFail("expected invalid native count failure")
        } catch let error as BareIPCTransport.Error {
            guard case let .writeFailed(underlying) = error else {
                return XCTFail("expected writeFailed, got \(error)")
            }
            XCTAssertEqual(
                (underlying as? BareRPCProtocolError)?.reason,
                "BareIPC.write returned an invalid byte count"
            )
        } catch {
            XCTFail("expected BareIPCTransport.Error, got \(error)")
        }
        await transport.close()
        XCTAssertEqual(writer.offers.count, 1)
    }

    func testPendingWriteByteLimitRejectsBackpressureWithoutNativeAdmission() async throws {
        let writer = ScriptedSyncWriter(results: Array(repeating: 0, count: 32))
        let transport = BareIPCTransport.__testTransport(
            maximumInboundBufferedBytes: 64,
            maximumPendingWriteCount: 4,
            maximumPendingWriteBytes: 4,
            write: { writer.write($0) }
        )
        let active = Task { try await transport.write(Data([0x01, 0x02, 0x03])) }
        try await waitUntil("active write to reach native pump") { !writer.offers.isEmpty }

        do {
            try await transport.write(Data([0x04, 0x05]))
            XCTFail("expected bounded queue rejection")
        } catch let error as BareIPCTransport.Error {
            guard case .writeQueueCapacityExceeded = error else {
                return XCTFail("expected writeQueueCapacityExceeded, got \(error)")
            }
        }

        await transport.close()
        _ = try? await active.value
    }

    func testPendingWriteCountLimitRejectsBackpressureAtExactBoundary() async throws {
        let writer = ScriptedSyncWriter(results: Array(repeating: 0, count: 32))
        let transport = BareIPCTransport.__testTransport(
            maximumInboundBufferedBytes: 64,
            maximumPendingWriteCount: 1,
            maximumPendingWriteBytes: 1,
            write: { writer.write($0) }
        )
        let active = Task { try await transport.write(Data([0x01])) }
        try await waitUntil("one exact-boundary write to reach native pump") {
            transport.__testWriteState().pendingCount == 1 && !writer.offers.isEmpty
        }

        do {
            try await transport.write(Data())
            XCTFail("expected bounded write-count rejection")
        } catch let error as BareIPCTransport.Error {
            guard case .writeQueueCapacityExceeded = error else {
                return XCTFail("expected writeQueueCapacityExceeded, got \(error)")
            }
        } catch {
            XCTFail("expected BareIPCTransport.Error, got \(error)")
        }

        XCTAssertFalse(writer.offers.isEmpty)
        XCTAssertTrue(writer.offers.allSatisfy { $0 == Data([0x01]) })
        XCTAssertEqual(transport.__testWriteState().pendingCount, 1)
        await transport.close()
        _ = try? await active.value
    }

    func testWriteAfterCloseIsRejectedBeforeBackendAdmission() async {
        let probe = BackendProbe()
        let transport = makeTransport(probe: probe)

        await transport.close()

        do {
            try await transport.write(Data([0xca, 0xfe]))
            XCTFail("expected a post-close write to be rejected")
        } catch let error as BareIPCTransport.Error {
            guard case .writeFailedBecauseTransportClosed = error else {
                return XCTFail("expected writeFailedBecauseTransportClosed, got \(error)")
            }
        } catch {
            XCTFail("expected BareIPCTransport.Error, got \(error)")
        }

        XCTAssertTrue(probe.writes.isEmpty)
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
    }

    func testWriteNormalizesBackendFailureWithoutDiscardingUnderlyingError() async {
        let probe = BackendProbe()
        let transport = makeTransport(
            probe: probe,
            write: { _ in
                errno = EIO
                return -2
            }
        )

        do {
            try await transport.write(Data([0x01]))
            XCTFail("expected write failure")
        } catch let error as BareIPCTransport.Error {
            guard case let .writeFailed(captured) = error else {
                await transport.close()
                return XCTFail("expected writeFailed, got \(error)")
            }
            XCTAssertEqual((captured as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((captured as NSError).code, Int(EIO))
        } catch {
            XCTFail("expected BareIPCTransport.Error, got \(error)")
        }

        await transport.close()
    }

    func testCancellationDuringWriteRemainsCancellationAndClosesExactlyOnce() async throws {
        let writeEntered = expectation(description: "backend write entered")
        let events = LifecycleEventRecorder()
        let probe = BackendProbe(
            onClearReadable: { events.record("readable-cleared") },
            onCloseIPC: { events.record("ipc-closed") },
            onTerminateWorklet: { events.record("worklet-terminated") }
        )
        let transport = makeTransport(
            probe: probe,
            write: { _ in
                if events.recordFirst("write-entered") { writeEntered.fulfill() }
                return 0
            }
        )
        let writeTask = Task {
            try await transport.write(Data([0x01]))
        }

        await fulfillment(of: [writeEntered], timeout: 5)
        writeTask.cancel()

        // The synchronous BareIPC write pump treats zero bytes as would-block and
        // rechecks cancellation/closure before retrying.
        try await waitUntil("cancellation began close while write remained active") {
            events.values.contains("ipc-closed")
        }
        XCTAssertEqual(probe.closeIPCCount, 1)

        do {
            try await writeTask.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation is never rewritten as a native write failure.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        // Synchronize with the cancellation handler's unstructured close task and
        // exercise the completed idempotent-close path.
        await transport.close()
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
        XCTAssertEqual(events.values, [
            "write-entered",
            "ipc-closed",
            "worklet-terminated",
        ])
    }

    func testCloseCancelsAdmittedNativeWriteBeforeTeardown() async throws {
        let writeEntered = expectation(description: "backend write entered")
        let events = LifecycleEventRecorder()
        let probe = BackendProbe(
            onClearReadable: { events.record("readable-cleared") },
            onCloseIPC: { events.record("ipc-closed") },
            onTerminateWorklet: { events.record("worklet-terminated") }
        )
        let transport = makeTransport(
            probe: probe,
            write: { _ in
                if events.recordFirst("write-entered") { writeEntered.fulfill() }
                return 0
            }
        )

        let writeTask = Task.detached { try await transport.write(Data([0x01])) }
        await fulfillment(of: [writeEntered], timeout: 5)
        let closeTask = Task.detached { await transport.close() }

        do {
            try await writeTask.value
            XCTFail("expected close to fail the pending native write")
        } catch let error as BareIPCTransport.Error {
            guard case .writeFailedBecauseTransportClosed = error else {
                return XCTFail("expected writeFailedBecauseTransportClosed, got \(error)")
            }
        }
        await closeTask.value

        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
        XCTAssertEqual(events.values, [
            "write-entered",
            "ipc-closed",
            "worklet-terminated",
        ])
    }

    func testCloseLeavesReadableSetterUntouchedAndRejectsStaleCallback() async throws {
        let probe = BackendProbe(reads: [Data([0x01])])
        let transport = makeTransport(probe: probe)
        let staleCallback = try XCTUnwrap(probe.captureReadable())

        await transport.close()

        XCTAssertEqual(probe.clearReadableCount, 0)
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)

        // Explicit close leaves the native callback property untouched because its
        // nonatomic setter races BareKit's poll queue. Both installed/stale blocks
        // observe the closed admission state before touching native IPC.
        probe.fireReadable()
        staleCallback()
        XCTAssertEqual(probe.readCount, 0)
    }

    func testCloseWaitsForInFlightReadableDrainBeforeNativeTeardown() async throws {
        let readEntered = expectation(description: "readable drain entered native read")
        let releaseRead = DispatchSemaphore(value: 0)
        let events = LifecycleEventRecorder()
        let probe = BackendProbe(
            onRead: {
                events.record("read-entered")
                readEntered.fulfill()
                if releaseRead.wait(timeout: .now() + 10) == .timedOut {
                    events.record("read-release-timed-out")
                }
                events.record("read-returned")
                return nil
            },
            onClearReadable: { events.record("readable-cleared") },
            onCloseIPC: { events.record("ipc-closed") },
            onTerminateWorklet: { events.record("worklet-terminated") }
        )
        let transport = makeTransport(probe: probe)
        defer { releaseRead.signal() }

        let readableTask = Task.detached { probe.fireReadable() }
        await fulfillment(of: [readEntered], timeout: 5)
        let closeTask = Task.detached { await transport.close() }

        try await waitUntil("close sealed readable admission") {
            transport.__testCloseState().closed
        }
        XCTAssertEqual(probe.closeIPCCount, 0, "native close overlapped an active read")

        releaseRead.signal()
        await readableTask.value
        await closeTask.value

        XCTAssertEqual(probe.clearReadableCount, 0)
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
        XCTAssertEqual(events.values, [
            "read-entered",
            "read-returned",
            "ipc-closed",
            "worklet-terminated",
        ])
    }

    func testCloseWaitsForActiveSynchronousWriteAndFailsQueuedWritersExactlyOnce() async throws {
        let entered = expectation(description: "synchronous native write entered")
        let release = DispatchSemaphore(value: 0)
        let probe = BackendProbe()
        let writer = BlockingSyncWriter(onFirstWrite: { entered.fulfill() }, release: release)
        let transport = makeTransport(probe: probe, write: { writer.write($0) })
        defer { release.signal() }

        let active = Task { try await transport.write(Data([0x01])) }
        await fulfillment(of: [entered], timeout: 5)
        let queued = Task { try await transport.write(Data([0x02])) }
        try await waitUntil("second writer to enter FIFO") {
            transport.__testWriteState().pendingCount == 2
        }
        let closing = Task { await transport.close() }
        try await waitUntil("close to seal write admission") {
            transport.__testCloseState().closed
        }
        XCTAssertEqual(probe.closeIPCCount, 0)
        XCTAssertEqual(writer.callCount, 1)

        release.signal()
        let activeResult = await active.result
        let queuedResult = await queued.result
        await closing.value
        Self.assertClosedWrite(activeResult)
        Self.assertClosedWrite(queuedResult)
        XCTAssertEqual(writer.callCount, 1)
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
    }

    func testNativeWriteFailureSealsGenerationBeforeQueuedWriterCanStart() async throws {
        let entered = expectation(description: "failing native write entered")
        let release = DispatchSemaphore(value: 0)
        let probe = BackendProbe()
        let writer = BlockingSyncWriter(
            result: -2,
            onFirstWrite: { entered.fulfill() },
            release: release
        )
        let transport = makeTransport(probe: probe, write: { writer.write($0) })
        defer { release.signal() }

        let failing = Task { try await transport.write(Data([0x01])) }
        await fulfillment(of: [entered], timeout: 5)
        let queued = Task { try await transport.write(Data([0x02])) }
        try await waitUntil("second writer to enter FIFO") {
            transport.__testWriteState().pendingCount == 2
        }
        release.signal()
        let failingResult = await failing.result
        let queuedResult = await queued.result
        await transport.close()

        if case let .failure(error as BareIPCTransport.Error) = failingResult,
           case let .writeFailed(underlying) = error {
            XCTAssertEqual((underlying as NSError).domain, NSPOSIXErrorDomain)
        } else {
            XCTFail("expected first writer to surface native failure")
        }
        Self.assertClosedWrite(queuedResult)
        XCTAssertEqual(writer.callCount, 1)
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
    }

    func testCloseStopsContinuouslyReadableDrainWithoutWaitingForWouldBlockOrEOF() async throws {
        let readEntered = expectation(description: "readable drain entered native read")
        let closeCompleted = expectation(description: "close completed")
        let continuousReads = ContinuousReadControl()
        let probe = BackendProbe(
            onRead: {
                continuousReads.next {
                    readEntered.fulfill()
                }
            },
            onClearReadable: {}
        )
        let transport = makeTransport(probe: probe)
        defer { continuousReads.stop() }

        let readableTask = Task.detached { probe.fireReadable() }
        await fulfillment(of: [readEntered], timeout: 5)
        let closeTask = Task.detached {
            await transport.close()
            closeCompleted.fulfill()
        }
        try await waitUntil("close sealed readable admission") {
            transport.__testCloseState().closed
        }
        continuousReads.markCloseBegan()

        // The first read remains data-producing after close marks the transport
        // closed. The drain must observe that state before attempting a second read;
        // no would-block or zero-byte EOF is needed to release close's quiescence wait.
        await fulfillment(of: [closeCompleted], timeout: 5)
        continuousReads.stop()
        await readableTask.value
        await closeTask.value

        XCTAssertEqual(probe.readCount, 1)
        XCTAssertEqual(continuousReads.readCount, 1)
        XCTAssertEqual(probe.clearReadableCount, 0)
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
    }

    func testConcurrentCloseHasOneOwnerAndWaitsForNativeTeardown() async throws {
        let closeEntered = expectation(description: "native close entered")
        let releaseClose = DispatchSemaphore(value: 0)
        let probe = BackendProbe(onCloseIPC: {
            closeEntered.fulfill()
            _ = releaseClose.wait(timeout: .now() + 10)
        })
        let transport = makeTransport(probe: probe)
        let owner = Task.detached { await transport.close() }

        await fulfillment(of: [closeEntered], timeout: 5)
        let followers = (0..<8).map { _ in
            Task.detached { await transport.close() }
        }
        try await waitUntil("all concurrent close callers are waiting") {
            transport.__testCloseState().waiterCount == followers.count
        }

        releaseClose.signal()
        await owner.value
        for follower in followers { await follower.value }

        let completed = transport.__testCloseState()
        XCTAssertTrue(completed.closed)
        XCTAssertTrue(completed.finished)
        XCTAssertEqual(completed.waiterCount, 0)
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)

        // Exercise the post-completion idempotent path as well as queued waiters.
        await transport.close()
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
    }

    func testInboundStreamCanBeClaimedOnlyOnce() async throws {
        let probe = BackendProbe()
        let transport = makeTransport(probe: probe)
        _ = transport.inboundStream()
        var duplicate = transport.inboundStream().makeAsyncIterator()

        do {
            _ = try await duplicate.next()
            XCTFail("expected duplicate inbound-stream claim to fail")
        } catch let error as BareRPCProtocolError {
            XCTAssertEqual(
                error.reason,
                "transport inboundStream() may be claimed only once"
            )
        } catch {
            XCTFail("expected BareRPCProtocolError, got \(error)")
        }

        await transport.close()
    }

    func testLateReadableCallbackDoesNothingAfterTransportDeinit() async throws {
        let probe = BackendProbe(reads: [Data([0x01])])
        var transport: BareIPCTransport? = makeTransport(probe: probe)
        let weakTransport = WeakReference(transport)
        let staleCallback = try XCTUnwrap(probe.captureReadable())

        await transport?.close()
        transport = nil

        XCTAssertNil(weakTransport.value)
        staleCallback()
        XCTAssertEqual(probe.readCount, 0)
        XCTAssertEqual(probe.closeIPCCount, 1)
        XCTAssertEqual(probe.terminateWorkletCount, 1)
    }

    private func makeTransport(
        maximumInboundBufferedBytes: Int = 64,
        probe: BackendProbe,
        write: (@Sendable (Data) -> Int)? = nil
    ) -> BareIPCTransport {
        BareIPCTransport.__testTransport(
            maximumInboundBufferedBytes: maximumInboundBufferedBytes,
            read: { try probe.read() },
            installReadable: { probe.installReadable($0) },
            clearReadable: { probe.clearReadable() },
            write: write ?? {
                probe.recordWrite($0)
                return $0.count
            },
            closeIPC: { probe.closeIPC() },
            terminateWorklet: { probe.terminateWorklet() }
        )
    }

    private func waitUntil(
        _ description: String,
        predicate: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard clock.now < deadline else {
                XCTFail("timed out waiting for \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func assertClosedWrite(_ result: Result<Void, Swift.Error>) {
        guard case let .failure(error as BareIPCTransport.Error) = result,
              case .writeFailedBecauseTransportClosed = error else {
            return XCTFail("expected writeFailedBecauseTransportClosed, got \(result)")
        }
    }
}

private struct MarkerError: Error, CustomStringConvertible, Sendable {
    let message: String
    var description: String { message }
}

private final class WeakReference<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object?) {
        self.value = value
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyOpen = lock.withLock { () -> Bool in
                guard !isOpen else { return true }
                waiters.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }

    func open() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !isOpen else { return [] }
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }
}

private final class LifecycleEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [String] = []

    var values: [String] { lock.withLock { recordedValues } }

    func record(_ value: String) {
        lock.withLock { recordedValues.append(value) }
    }

    func recordFirst(_ value: String) -> Bool {
        lock.withLock {
            guard !recordedValues.contains(value) else { return false }
            recordedValues.append(value)
            return true
        }
    }
}

private final class WriteCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let firstWriteGate = DispatchSemaphore(value: 0)
    private var recordedPayloads: [Data] = []

    var count: Int { lock.withLock { recordedPayloads.count } }
    var payloads: [Data] { lock.withLock { recordedPayloads } }

    func write(_ data: Data) -> Int {
        let index = lock.withLock { () -> Int in
            recordedPayloads.append(data)
            return recordedPayloads.count - 1
        }
        if index == 0 { _ = firstWriteGate.wait(timeout: .now() + 10) }
        return data.count
    }

    func allowFirstWrite() { firstWriteGate.signal() }
}

private final class ScriptedSyncWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Int]
    private var recordedOffers: [Data] = []

    init(results: [Int]) { self.results = results }
    var offers: [Data] { lock.withLock { recordedOffers } }

    func write(_ data: Data) -> Int {
        lock.withLock {
            recordedOffers.append(data)
            return results.isEmpty ? 0 : results.removeFirst()
        }
    }
}

private final class BlockingSyncWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let result: Int
    private let onFirstWrite: () -> Void
    private let release: DispatchSemaphore
    private var recordedCallCount = 0

    init(
        result: Int = 0,
        onFirstWrite: @escaping () -> Void,
        release: DispatchSemaphore
    ) {
        self.result = result
        self.onFirstWrite = onFirstWrite
        self.release = release
    }

    var callCount: Int { lock.withLock { recordedCallCount } }

    func write(_ data: Data) -> Int {
        let first = lock.withLock { () -> Bool in
            recordedCallCount += 1
            return recordedCallCount == 1
        }
        if first {
            onFirstWrite()
            _ = release.wait(timeout: .now() + 10)
        }
        return result
    }
}

private final class ContinuousReadControl: @unchecked Sendable {
    private let lock = NSLock()
    private let closeBegan = DispatchSemaphore(value: 0)
    private var stopped = false
    private var closeWasMarked = false
    private var recordedReadCount = 0

    var readCount: Int { lock.withLock { recordedReadCount } }

    func next(onFirstRead: () -> Void) -> Data? {
        let state = lock.withLock { () -> (allowed: Bool, first: Bool) in
            guard !stopped else { return (false, false) }
            recordedReadCount += 1
            return (true, recordedReadCount == 1)
        }
        guard state.allowed else { return nil }
        if state.first {
            onFirstRead()
            if !lock.withLock({ closeWasMarked }) {
                _ = closeBegan.wait(timeout: .now() + 10)
            }
        } else {
            // Bound CPU use if a regression reintroduces the infinite drain. The
            // backend still returns bytes on every read until test cleanup stops it.
            Thread.sleep(forTimeInterval: 0.001)
        }
        return lock.withLock { stopped ? nil : Data([0x7f]) }
    }

    func markCloseBegan() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !closeWasMarked else { return false }
            closeWasMarked = true
            return true
        }
        if shouldSignal { closeBegan.signal() }
    }

    func stop() {
        let shouldSignal = lock.withLock { () -> Bool in
            stopped = true
            guard !closeWasMarked else { return false }
            closeWasMarked = true
            return true
        }
        if shouldSignal { closeBegan.signal() }
    }
}

private final class BackendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedReads: [Data?]
    private var readable: (() -> Void)?
    private var recordedWrites: [Data] = []
    private var recordedReadCount = 0
    private var recordedClearReadableCount = 0
    private var recordedCloseIPCCount = 0
    private var recordedTerminateWorkletCount = 0
    private let onRead: (() throws -> Data?)?
    private let onClearReadable: (() -> Void)?
    private let onCloseIPC: (() -> Void)?
    private let onTerminateWorklet: (() -> Void)?

    init(
        reads: [Data?] = [],
        onRead: (() throws -> Data?)? = nil,
        onClearReadable: (() -> Void)? = nil,
        onCloseIPC: (() -> Void)? = nil,
        onTerminateWorklet: (() -> Void)? = nil
    ) {
        self.queuedReads = reads
        self.onRead = onRead
        self.onClearReadable = onClearReadable
        self.onCloseIPC = onCloseIPC
        self.onTerminateWorklet = onTerminateWorklet
    }

    var writes: [Data] { lock.withLock { recordedWrites } }
    var readCount: Int { lock.withLock { recordedReadCount } }
    var clearReadableCount: Int { lock.withLock { recordedClearReadableCount } }
    var closeIPCCount: Int { lock.withLock { recordedCloseIPCCount } }
    var terminateWorkletCount: Int { lock.withLock { recordedTerminateWorkletCount } }

    func installReadable(_ handler: @escaping () -> Void) {
        lock.withLock { readable = handler }
    }

    func captureReadable() -> (() -> Void)? {
        lock.withLock { readable }
    }

    func clearReadable() {
        lock.withLock {
            recordedClearReadableCount += 1
            readable = nil
        }
        onClearReadable?()
    }

    func fireReadable() {
        let handler = lock.withLock { readable }
        handler?()
    }

    func read() throws -> Data? {
        if let onRead {
            lock.withLock { recordedReadCount += 1 }
            return try onRead()
        }
        return lock.withLock { () -> Data? in
            recordedReadCount += 1
            guard !queuedReads.isEmpty else { return nil }
            return queuedReads.removeFirst()
        }
    }

    func recordWrite(_ data: Data) {
        lock.withLock { recordedWrites.append(data) }
    }

    func closeIPC() {
        lock.withLock { recordedCloseIPCCount += 1 }
        onCloseIPC?()
    }

    func terminateWorklet() {
        lock.withLock { recordedTerminateWorkletCount += 1 }
        onTerminateWorklet?()
    }
}
