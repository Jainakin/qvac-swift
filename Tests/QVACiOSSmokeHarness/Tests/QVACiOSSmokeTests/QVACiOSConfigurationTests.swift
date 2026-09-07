import Foundation
import XCTest
@testable import QVACClient

final class QVACiOSConfigurationTests: XCTestCase {
    func testIOSRuntimeContextCurrentMatchesMobileContract() {
        XCTAssertEqual(
            QVACRuntimeContext.current,
            QVACRuntimeContext(
                runtime: "react-native",
                platform: "ios",
                deviceModel: nil,
                deviceBrand: "Apple"
            )
        )
    }

    func testIOSConfigurationPreservesEveryWorkletOption() {
        let source = Data([0x01, 0x02, 0x03])
        let configuration = QVACClient.Configuration.iOS(
            workletBundleData: source,
            entryName: "/custom.bundle",
            arguments: ["host", "worker.js", #"{"HOME_DIR":"/tmp/qvac"}"#],
            memoryLimit: 128 * 1_024 * 1_024,
            assets: "/tmp/assets"
        )

        guard case .iOSWorklet(let worklet) = configuration.storage else {
            return XCTFail("expected iOS worklet configuration")
        }
        XCTAssertEqual(worklet.workletSource, source)
        XCTAssertEqual(worklet.workletEntryName, "/custom.bundle")
        XCTAssertEqual(worklet.arguments, [
            "host",
            "worker.js",
            #"{"HOME_DIR":"/tmp/qvac"}"#,
        ])
        XCTAssertEqual(worklet.memoryLimit, 128 * 1_024 * 1_024)
        XCTAssertEqual(worklet.assets, "/tmp/assets")

        let internalConfiguration = QVACClient.Configuration.iOSWorklet(.init(
            workletSource: source,
            workletEntryName: "/internal.bundle",
            arguments: ["internal"],
            memoryLimit: 64 * 1_024 * 1_024,
            assets: nil
        ))
        guard case .iOSWorklet(let internalWorklet) = internalConfiguration.storage else {
            return XCTFail("expected internal iOS worklet configuration")
        }
        XCTAssertEqual(internalWorklet.workletSource, source)
        XCTAssertEqual(internalWorklet.workletEntryName, "/internal.bundle")
        XCTAssertEqual(internalWorklet.arguments, ["internal"])
        XCTAssertEqual(internalWorklet.memoryLimit, 64 * 1_024 * 1_024)
        XCTAssertNil(internalWorklet.assets)
    }

    func testBundledConfigurationLoadsPackagedWorkerAndPreservesOverrides() throws {
        let arguments = QVACClient.Configuration.defaultWorkletArguments(
            homeDirectory: URL(fileURLWithPath: "/tmp/qvac-bundled-test")
        )
        let configuration = try QVACClient.Configuration.iOSWithBundledResource(
            entryName: "/packaged.bundle",
            arguments: arguments,
            memoryLimit: 256 * 1_024 * 1_024,
            assets: "/tmp/packaged-assets"
        )

        guard case .iOSWorklet(let worklet) = configuration.storage else {
            return XCTFail("expected bundled iOS worklet configuration")
        }
        XCTAssertGreaterThan(worklet.workletSource.count, 1_000_000)
        XCTAssertEqual(worklet.workletEntryName, "/packaged.bundle")
        XCTAssertEqual(worklet.arguments, arguments)
        XCTAssertEqual(worklet.memoryLimit, 256 * 1_024 * 1_024)
        XCTAssertEqual(worklet.assets, "/tmp/packaged-assets")
    }

    func testDefaultWorkletArgumentsEscapeArbitraryHomePath() throws {
        let home = URL(fileURLWithPath: "/tmp/qvac-\"quoted\\path\nline")
        let arguments = QVACClient.Configuration.defaultWorkletArguments(homeDirectory: home)

        XCTAssertEqual(arguments.count, 3)
        XCTAssertEqual(arguments[0], "qvac-swift-client")
        XCTAssertEqual(arguments[1], "worker.js")
        let config = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as? [String: String]
        )
        XCTAssertEqual(config["HOME_DIR"], home.path)
    }

    func testWorkletBundleReadFailureUsesPublicTransportError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("qvac-missing-\(UUID().uuidString).bundle")

        XCTAssertThrowsError(
            try QVACClient.Configuration.readWorkletBundleData(from: missing)
        ) { error in
            guard case let QVACError.transport(reason, underlying) = error else {
                return XCTFail("expected QVACError.transport, got \(error)")
            }
            XCTAssertEqual(reason, "could not read bundled worker.mobile.bundle")
            XCTAssertNotNil(underlying)
        }
    }

    func testPublicInitializerEncodesMobileHandshakeAndPerformsBoundedShutdown() async throws {
        enum InvalidLimit {
            case handshakeTimeout
            case wireMessage
            case inlineBinaryBytes
            case inlineBinaryItems
            case batchPrompts
            case accumulatedResult
            case vlaAction
            case metadataResponse
            case registryResponse
            case outboundPayload
            case bufferedStream
        }
        let invalidLimits: [InvalidLimit] = [
            .handshakeTimeout,
            .wireMessage,
            .inlineBinaryBytes,
            .inlineBinaryItems,
            .batchPrompts,
            .accumulatedResult,
            .vlaAction,
            .metadataResponse,
            .registryResponse,
            .outboundPayload,
            .bufferedStream,
        ]
        for invalidLimit in invalidLimits {
            var handshakeTimeout = Duration.seconds(2)
            var wireMessageBytes = 1_024
            var inlineBinaryBytes = 1
            var inlineBinaryItems = 1
            var batchPrompts = 1
            var accumulatedResultBytes: Int?
            var vlaActionBytes: Int?
            var metadataResponseBytes: Int?
            var registryResponseBytes: Int?
            var outboundPayloadBytes: Int?
            var bufferedStreamBytes: Int?
            let expectedReason: String

            switch invalidLimit {
            case .handshakeTimeout:
                handshakeTimeout = .zero
                expectedReason = "initHandshakeTimeout must be greater than zero"
            case .wireMessage:
                wireMessageBytes = 0
                expectedReason = "maximumWireMessageBytes must be between 1 and UInt32.max"
            case .inlineBinaryBytes:
                inlineBinaryBytes = 0
                expectedReason = "maximumInlineBinaryBytes must be between 1 and UInt32.max"
            case .inlineBinaryItems:
                inlineBinaryItems = 0
                expectedReason = "maximumInlineBinaryItems must be between 1 and UInt32.max"
            case .batchPrompts:
                batchPrompts = 0
                expectedReason = "maximumBatchPrompts must be between 1 and UInt32.max"
            case .accumulatedResult:
                accumulatedResultBytes = 0
                expectedReason = "maximumAccumulatedResultBytes must be between 1 and UInt32.max"
            case .vlaAction:
                vlaActionBytes = 0
                expectedReason = "maximumVLAActionBytes must be between 1 and both "
                    + "maximumWireMessageBytes and maximumAccumulatedResultBytes"
            case .metadataResponse:
                metadataResponseBytes = 0
                expectedReason = "maximumMetadataResponseBytes must be between 1 and both "
                    + "maximumWireMessageBytes and maximumAccumulatedResultBytes"
            case .registryResponse:
                registryResponseBytes = 0
                expectedReason = "maximumRegistryResponseBytes must be between 1 and both "
                    + "maximumWireMessageBytes and maximumAccumulatedResultBytes"
            case .outboundPayload:
                outboundPayloadBytes = 0
                expectedReason = "maximumOutboundPayloadBytes must be between 1 and "
                    + "maximumWireMessageBytes"
            case .bufferedStream:
                bufferedStreamBytes = 0
                expectedReason = "maximumBufferedStreamBytes must be between 1 and UInt32.max"
            }

            do {
                let client = try await QVACClient(
                    configuration: .testing(HandshakeTransport()),
                    initHandshakeTimeout: handshakeTimeout,
                    maximumWireMessageBytes: wireMessageBytes,
                    maximumOutboundPayloadBytes: outboundPayloadBytes,
                    maximumInlineBinaryBytes: inlineBinaryBytes,
                    maximumInlineBinaryItems: inlineBinaryItems,
                    maximumBatchPrompts: batchPrompts,
                    maximumAccumulatedResultBytes: accumulatedResultBytes,
                    maximumVLAActionBytes: vlaActionBytes,
                    maximumMetadataResponseBytes: metadataResponseBytes,
                    maximumRegistryResponseBytes: registryResponseBytes,
                    maximumBufferedStreamBytes: bufferedStreamBytes,
                    logger: nil
                )
                await client.close()
                XCTFail("expected invalid limit rejection for \(invalidLimit)")
            } catch QVACError.invalidArgument(let reason) {
                XCTAssertEqual(reason, expectedReason)
            } catch {
                XCTFail("unexpected invalid-limit error: \(error)")
            }
        }

        let transport = HandshakeTransport()
        let runtime = QVACRuntimeContext.current
        let config: JSONValue = .object(["mode": .string("ios-test")])
        let initialization = Task {
            try await QVACClient(
                configuration: .testing(transport, shutdownBeforeClose: true),
                runtimeContext: runtime,
                config: config,
                initHandshakeTimeout: .seconds(2),
                logger: nil
            )
        }

        let initRequest = try await Self.waitForRequest(index: 0, on: transport)
        let initObject = try Self.object(from: initRequest.payload)
        XCTAssertEqual(initObject["type"] as? String, "__init_config")
        XCTAssertEqual((initObject["config"] as? [String: String])?["mode"], "ios-test")
        let encodedRuntime = try XCTUnwrap(initObject["runtimeContext"] as? [String: Any])
        XCTAssertEqual(encodedRuntime["runtime"] as? String, "react-native")
        XCTAssertEqual(encodedRuntime["platform"] as? String, "ios")
        XCTAssertEqual(encodedRuntime["deviceBrand"] as? String, "Apple")
        await transport.reply(id: initRequest.id, success: true)

        let client = try await initialization.value
        let closing = Task { await client.close() }
        let shutdownRequest = try await Self.waitForRequest(index: 1, on: transport)
        XCTAssertEqual(
            try Self.object(from: shutdownRequest.payload)["type"] as? String,
            "__shutdown__"
        )
        await transport.reply(id: shutdownRequest.id, success: true)
        await closing.value
        await client.close()

        let closeCount = await transport.closeCount()
        let writeAfterCloseCount = await transport.writeAfterCloseCount()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(writeAfterCloseCount, 0)
    }

    func testRejectedInitHandshakeIsNormalizedAndClosesTransport() async throws {
        let transport = HandshakeTransport()
        let initialization = Task {
            try await QVACClient(
                configuration: .testing(transport),
                runtimeContext: .current,
                initHandshakeTimeout: .seconds(2),
                logger: nil
            )
        }

        let request = try await Self.waitForRequest(index: 0, on: transport)
        await transport.reply(
            id: request.id,
            success: false,
            error: "mobile worker rejected config"
        )

        do {
            let client = try await initialization.value
            await client.close()
            XCTFail("expected rejected init handshake")
        } catch let error as QVACError {
            guard case let .transport(reason, underlying) = error else {
                return XCTFail("expected QVACError.transport, got \(error)")
            }
            XCTAssertEqual(
                reason,
                "init_config rejected by worker: mobile worker rejected config"
            )
            XCTAssertTrue(underlying is QVACInitConfigFailed)
        } catch {
            XCTFail("public initializer leaked non-QVAC error: \(error)")
        }

        let closeCount = await transport.closeCount()
        let writeAfterCloseCount = await transport.writeAfterCloseCount()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(writeAfterCloseCount, 0)
    }

    func testHandshakeHelpersRejectEmptyAndNegativeReplies() async throws {
        let cases: [(shutdown: Bool, success: Bool?, error: String?, expected: String)] = [
            (false, nil, nil, "empty reply"),
            (false, false, nil, "unknown error"),
            (true, nil, nil, "empty shutdown reply"),
            (true, false, nil, "shutdown rejected"),
            (true, false, "worker busy", "worker busy"),
        ]

        for fixture in cases {
            let transport = HandshakeTransport()
            let rpc = BareRPCClient(transport: transport)
            let request = Task {
                if fixture.shutdown {
                    try await QVACHandshake.sendShutdown(on: rpc, timeout: .seconds(2))
                } else {
                    try await QVACHandshake.sendInitConfig(
                        on: rpc,
                        runtimeContext: .current,
                        timeout: .seconds(2)
                    )
                }
            }
            let outbound = try await Self.waitForRequest(index: 0, on: transport)
            if let success = fixture.success {
                await transport.reply(
                    id: outbound.id,
                    success: success,
                    error: fixture.error
                )
            } else {
                await transport.replyEmpty(id: outbound.id)
            }

            do {
                try await request.value
                XCTFail("expected handshake failure: \(fixture.expected)")
            } catch let error as QVACInitConfigFailed {
                XCTAssertEqual(error.message, fixture.expected)
            } catch {
                XCTFail("unexpected handshake error: \(error)")
            }
            await rpc.close()
        }
    }

    private static func waitForRequest(
        index: Int,
        on transport: HandshakeTransport
    ) async throws -> (id: UInt64, payload: Data) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let reader = BareRPCFrameReader()
            try reader.append(await transport.outbound())
            var requests: [(UInt64, Data)] = []
            while let frame = reader.next() {
                guard case let .request(id, _, _, payload?) = frame else { continue }
                requests.append((id, payload))
            }
            if requests.indices.contains(index) { return requests[index] }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw TestDeadlineExceeded(context: "request \(index)")
    }

    private static func object(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct TestDeadlineExceeded: Error, CustomStringConvertible {
    let context: String
    var description: String { "timed out waiting for \(context)" }
}

private final class HandshakeInboundPipe: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }
}

private actor HandshakeTransport: BareTransport {
    nonisolated private let inbound = HandshakeInboundPipe()
    private var outboundBytes = Data()
    private var closed = false
    private var recordedCloseCount = 0
    private var recordedWriteAfterCloseCount = 0

    nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
        inbound.stream
    }

    func write(_ data: Data) async throws {
        guard !closed else {
            recordedWriteAfterCloseCount += 1
            throw BareRPCConnectionClosed()
        }
        outboundBytes.append(data)
    }

    func close() {
        guard !closed else { return }
        closed = true
        recordedCloseCount += 1
        inbound.continuation.finish()
    }

    func outbound() -> Data { outboundBytes }
    func closeCount() -> Int { recordedCloseCount }
    func writeAfterCloseCount() -> Int { recordedWriteAfterCloseCount }

    func reply(id: UInt64, success: Bool, error: String? = nil) {
        let data: Data
        if let error {
            data = Data(#"{"error":"\#(error)","success":\#(success)}"#.utf8)
        } else {
            data = Data(#"{"success":\#(success)}"#.utf8)
        }
        guard let frame = try? BareRPCCodec.encodeResponseFrame(
            id: id,
            stream: [],
            payload: .success(data),
            maximumBodyBytes: Int(UInt32.max)
        ) else {
            inbound.continuation.finish(throwing: BareRPCProtocolError("invalid test reply"))
            return
        }
        inbound.continuation.yield(frame)
    }

    func replyEmpty(id: UInt64) {
        guard let frame = try? BareRPCCodec.encodeResponseFrame(
            id: id,
            stream: [],
            payload: .success(nil),
            maximumBodyBytes: Int(UInt32.max)
        ) else {
            inbound.continuation.finish(throwing: BareRPCProtocolError("invalid test reply"))
            return
        }
        inbound.continuation.yield(frame)
    }
}
