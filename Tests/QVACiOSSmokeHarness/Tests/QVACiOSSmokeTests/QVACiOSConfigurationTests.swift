import Foundation
import XCTest
@testable import QVACClient

final class QVACiOSConfigurationTests: XCTestCase {
    /// This bounds the scripted RPC itself without coupling correctness to the
    /// much tighter scheduling assumptions that caused the former polling race.
    private static let scriptedHandshakeTimeout = Duration.seconds(10)

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

        let successReply = BareRPCResponsePayload.success(
            Data(#"{"success":true}"#.utf8)
        )
        let transport = HandshakeTransport(scriptedReplies: [successReply, successReply])
        let runtime = QVACRuntimeContext.current
        let config: JSONValue = .object(["mode": .string("ios-test")])
        let client: QVACClient
        do {
            client = try await QVACClient(
                configuration: .testing(transport, shutdownBeforeClose: true),
                runtimeContext: runtime,
                config: config,
                initHandshakeTimeout: Self.scriptedHandshakeTimeout,
                logger: nil
            )
        } catch {
            await transport.close()
            throw error
        }
        await client.close()
        await client.close()

        let requests = try Self.requests(in: await transport.outbound())
        XCTAssertEqual(requests.count, 2)
        let initRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(initRequest.command, 1)
        let initObject = try Self.object(from: initRequest.payload)
        XCTAssertEqual(initObject["type"] as? String, "__init_config")
        XCTAssertEqual((initObject["config"] as? [String: String])?["mode"], "ios-test")
        let encodedRuntime = try XCTUnwrap(initObject["runtimeContext"] as? [String: Any])
        XCTAssertEqual(encodedRuntime["runtime"] as? String, "react-native")
        XCTAssertEqual(encodedRuntime["platform"] as? String, "ios")
        XCTAssertEqual(encodedRuntime["deviceBrand"] as? String, "Apple")
        let shutdownRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(shutdownRequest.command, 1)
        XCTAssertEqual(
            try Self.object(from: shutdownRequest.payload)["type"] as? String,
            "__shutdown__"
        )

        let closeCount = await transport.closeCount()
        let writeAfterCloseCount = await transport.writeAfterCloseCount()
        let unusedReplyCount = await transport.unusedScriptedReplyCount()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(writeAfterCloseCount, 0)
        XCTAssertEqual(unusedReplyCount, 0)
    }

    func testRejectedInitHandshakeIsNormalizedAndClosesTransport() async throws {
        let transport = HandshakeTransport(scriptedReplies: [
            .success(Data(
                #"{"error":"mobile worker rejected config","success":false}"#.utf8
            )),
        ])
        let result: Result<QVACClient, Error>
        do {
            result = .success(try await QVACClient(
                configuration: .testing(transport),
                runtimeContext: .current,
                initHandshakeTimeout: Self.scriptedHandshakeTimeout,
                logger: nil
            ))
        } catch {
            result = .failure(error)
        }

        switch result {
        case .success(let client):
            await client.close()
            XCTFail("expected rejected init handshake")
        case .failure(let error as QVACError):
            if case let .transport(reason, underlying) = error {
                XCTAssertEqual(
                    reason,
                    "init_config rejected by worker: mobile worker rejected config"
                )
                XCTAssertTrue(underlying is QVACInitConfigFailed)
            } else {
                XCTFail("expected QVACError.transport, got \(error)")
            }
        case .failure(let error):
            XCTFail("public initializer leaked non-QVAC error: \(error)")
        }

        let requests = try Self.requests(in: await transport.outbound())
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.command, 1)
        XCTAssertEqual(
            try Self.object(from: request.payload)["type"] as? String,
            "__init_config"
        )
        let closeCount = await transport.closeCount()
        let writeAfterCloseCount = await transport.writeAfterCloseCount()
        let unusedReplyCount = await transport.unusedScriptedReplyCount()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(writeAfterCloseCount, 0)
        XCTAssertEqual(unusedReplyCount, 0)
    }

    func testHandshakeHelpersRejectEmptyAndNegativeReplies() async throws {
        let cases: [(
            label: String,
            shutdown: Bool,
            reply: BareRPCResponsePayload,
            expected: String
        )] = [
            ("empty init reply", false, .success(nil), "empty reply"),
            (
                "negative init reply without diagnostic",
                false,
                .success(Data(#"{"success":false}"#.utf8)),
                "unknown error"
            ),
            ("empty shutdown reply", true, .success(nil), "empty shutdown reply"),
            (
                "negative shutdown reply without diagnostic",
                true,
                .success(Data(#"{"success":false}"#.utf8)),
                "shutdown rejected"
            ),
            (
                "negative shutdown reply with diagnostic",
                true,
                .success(Data(#"{"error":"worker busy","success":false}"#.utf8)),
                "worker busy"
            ),
        ]

        for fixture in cases {
            let transport = HandshakeTransport(scriptedReplies: [fixture.reply])
            let rpc = BareRPCClient(transport: transport)

            let result: Result<Void, Error>
            do {
                if fixture.shutdown {
                    try await QVACHandshake.sendShutdown(
                        on: rpc,
                        timeout: Self.scriptedHandshakeTimeout
                    )
                } else {
                    try await QVACHandshake.sendInitConfig(
                        on: rpc,
                        runtimeContext: .current,
                        timeout: Self.scriptedHandshakeTimeout
                    )
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            let inFlight = await rpc.__testInFlightCounts()
            await rpc.close()

            switch result {
            case .success:
                XCTFail("\(fixture.label): expected handshake failure: \(fixture.expected)")
            case .failure(let error as QVACInitConfigFailed):
                XCTAssertEqual(error.message, fixture.expected, fixture.label)
            case .failure(let error):
                XCTFail("\(fixture.label): unexpected handshake error: \(error)")
            }

            XCTAssertEqual(inFlight.sends, 0, fixture.label)
            XCTAssertEqual(inFlight.streams, 0, fixture.label)
            XCTAssertEqual(inFlight.duplexes, 0, fixture.label)

            let requests = try Self.requests(in: await transport.outbound())
            XCTAssertEqual(requests.count, 1, fixture.label)
            let outbound = try XCTUnwrap(requests.first, fixture.label)
            XCTAssertEqual(outbound.command, 1, fixture.label)
            XCTAssertEqual(
                try Self.object(from: outbound.payload)["type"] as? String,
                fixture.shutdown ? "__shutdown__" : "__init_config",
                fixture.label
            )
            let closeCount = await transport.closeCount()
            let writeAfterCloseCount = await transport.writeAfterCloseCount()
            let unusedReplyCount = await transport.unusedScriptedReplyCount()
            XCTAssertEqual(closeCount, 1, fixture.label)
            XCTAssertEqual(writeAfterCloseCount, 0, fixture.label)
            XCTAssertEqual(unusedReplyCount, 0, fixture.label)
        }
    }

    private static func requests(
        in data: Data
    ) throws -> [(id: UInt64, command: UInt64, payload: Data)] {
        let reader = BareRPCFrameReader()
        try reader.append(data)
        var requests: [(UInt64, UInt64, Data)] = []
        while let frame = reader.next() {
            guard case let .request(id, command, _, payload?) = frame else { continue }
            requests.append((id, command, payload))
        }
        return requests
    }

    private static func object(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
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
    private let scriptedReplies: [BareRPCResponsePayload]
    private var outboundBytes = Data()
    private var closed = false
    private var nextScriptedReplyIndex = 0
    private var recordedCloseCount = 0
    private var recordedWriteAfterCloseCount = 0

    init(scriptedReplies: [BareRPCResponsePayload] = []) {
        self.scriptedReplies = scriptedReplies
    }

    nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
        inbound.stream
    }

    func write(_ data: Data) async throws {
        guard !closed else {
            recordedWriteAfterCloseCount += 1
            throw BareRPCConnectionClosed()
        }
        outboundBytes.append(data)

        guard scriptedReplies.indices.contains(nextScriptedReplyIndex) else { return }
        let reader = BareRPCFrameReader()
        try reader.append(data)
        while let frame = reader.next() {
            guard case let .request(id, _, _, _) = frame else { continue }
            let scriptedReply = scriptedReplies[nextScriptedReplyIndex]
            let response = try BareRPCCodec.encodeResponseFrame(
                id: id,
                stream: [],
                payload: scriptedReply,
                maximumBodyBytes: Int(UInt32.max)
            )
            nextScriptedReplyIndex += 1
            inbound.continuation.yield(response)
            return
        }
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
    func unusedScriptedReplyCount() -> Int {
        scriptedReplies.count - nextScriptedReplyIndex
    }
}
