import Foundation
import XCTest
@testable import QVACClient

/// Focused parity coverage for the public QVAC 0.17 duplex TTS adapter.
final class QVACTTSDuplexParityTests: XCTestCase {
    private final class InboundPipe: @unchecked Sendable {
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation

        init() {
            var captured: AsyncThrowingStream<Data, Error>.Continuation!
            stream = AsyncThrowingStream { captured = $0 }
            continuation = captured
        }
    }

    private actor MockTransport: BareTransport {
        nonisolated private let inbound = InboundPipe()
        private var outboundBytes = Data()
        private var closed = false
        private var acknowledgedDuplexIDs: Set<UInt64> = []

        nonisolated func inboundStream() -> AsyncThrowingStream<Data, Error> {
            inbound.stream
        }

        func write(_ data: Data) async throws {
            outboundBytes.append(data)
            let reader = BareRPCFrameReader()
            try reader.append(data)
            while let frame = reader.next() {
                guard case .request(let id, _, let flags, _) = frame,
                      flags.contains(.open),
                      acknowledgedDuplexIDs.insert(id).inserted else { continue }
                var acknowledgements = BareRPCCodec.__testEncodeStreamFrame(
                    id: id,
                    flags: [.request, .open]
                )
                acknowledgements.append(BareRPCCodec.__testEncodeStreamFrame(
                    id: id,
                    flags: [.response, .open]
                ))
                inbound.continuation.yield(acknowledgements)
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            inbound.continuation.finish()
        }

        func feed(_ data: Data) {
            inbound.continuation.yield(data)
        }

        func outbound() -> Data { outboundBytes }
    }

    private static func frames(in data: Data) -> [BareRPCFrame] {
        let reader = BareRPCFrameReader()
        try? reader.append(data)
        var result: [BareRPCFrame] = []
        while let frame = reader.next() { result.append(frame) }
        return result
    }

    private static func waitForFrames(
        _ count: Int,
        on transport: MockTransport,
        timeout: Duration = .seconds(1)
    ) async throws -> [BareRPCFrame] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let decoded = frames(in: await transport.outbound())
            if decoded.count >= count { return decoded }
            try await Task.sleep(for: .milliseconds(5))
        }
        let decoded = frames(in: await transport.outbound())
        XCTFail("timed out waiting for \(count) outbound bare-rpc frames; got \(decoded.count)")
        return decoded
    }

    private static func duplexRequestID(in frames: [BareRPCFrame]) throws -> UInt64 {
        for frame in frames {
            if case .stream(let id, let flags, .data) = frame,
               flags.contains(.request) {
                return id
            }
        }
        throw QVACError.protocolViolation("test peer did not observe a duplex request payload")
    }

    private static func feedDuplex(
        id: UInt64,
        records: [String],
        to transport: MockTransport
    ) async {
        var inbound = Data()
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.request, .open]
        ))
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .open]
        ))
        for record in records {
            inbound.append(BareRPCCodec.__testEncodeStreamFrame(
                id: id,
                flags: [.response, .data],
                payload: .data(Data((record + "\n").utf8))
            ))
        }
        inbound.append(BareRPCCodec.__testEncodeStreamFrame(
            id: id,
            flags: [.response, .end]
        ))
        await transport.feed(inbound)
    }

    func test_terminal_stats_are_preserved_on_the_terminal_response_frame() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.textToSpeechStream(
            modelId: "tts-model",
            rpcOptions: .init(timeout: nil)
        )
        let requestFrames = try await Self.waitForFrames(3, on: transport)
        let id = try Self.duplexRequestID(in: requestFrames)
        try await session.end()

        await Self.feedDuplex(
            id: id,
            records: [
                #"{"type":"textToSpeechStream","buffer":[32767,-32768],"done":false,"chunkIndex":0,"sentenceChunk":"hello"}"#,
                #"{"type":"textToSpeechStream","buffer":[],"done":true,"stats":{"audioDuration":125.5,"totalSamples":2,"enhancerBackendDevice":1,"enhancerBackendId":7}}"#,
            ],
            to: transport
        )

        var frames: [QVACClient.TtsStreamChunk] = []
        for try await frame in session.chunks { frames.append(frame) }

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].buffer, [32767, -32768])
        XCTAssertEqual(frames[0].chunkIndex, 0)
        XCTAssertEqual(frames[0].sentenceChunk, "hello")
        XCTAssertFalse(frames[0].done)
        XCTAssertNil(frames[0].stats)

        XCTAssertTrue(frames[1].buffer.isEmpty)
        XCTAssertTrue(frames[1].done)
        XCTAssertEqual(frames[1].stats?.audioDuration, 125.5)
        XCTAssertEqual(frames[1].stats?.totalSamples, 2)
        XCTAssertEqual(frames[1].stats?.enhancerBackendDevice, 1)
        XCTAssertEqual(frames[1].stats?.enhancerBackendId, 7)
        await client.close()
    }

    func test_data_write_forwards_the_exact_utf8_fragment() async throws {
        let transport = MockTransport()
        let client = QVACClient(testing: transport)
        let session = try await client.textToSpeechStream(
            modelId: "tts-model",
            rpcOptions: .init(timeout: nil)
        )
        let initialFrames = try await Self.waitForFrames(3, on: transport)
        let id = try Self.duplexRequestID(in: initialFrames)

        let fragment = Data("नमस्ते".utf8)
        try await session.write(fragment)
        try await session.end()
        let outbound = try await Self.waitForFrames(5, on: transport)
        let requestData = outbound.compactMap { frame -> Data? in
            guard case .stream(_, let flags, .data(let data)) = frame,
                  flags.contains(.request) else { return nil }
            return data
        }
        XCTAssertEqual(requestData.last, fragment)

        await Self.feedDuplex(
            id: id,
            records: [#"{"type":"textToSpeechStream","buffer":[],"done":true}"#],
            to: transport
        )
        var terminalFrames: [QVACClient.TtsStreamChunk] = []
        for try await frame in session.chunks { terminalFrames.append(frame) }
        XCTAssertEqual(terminalFrames.count, 1)
        XCTAssertTrue(terminalFrames[0].done)
        await client.close()
    }
}
