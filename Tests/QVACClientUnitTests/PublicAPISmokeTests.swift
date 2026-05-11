// PublicAPISmokeTests — Codable round-trip sanity for the M2 public API surface.
//
// These tests build typed Swift requests, encode them with the same JSONEncoder the
// client uses, decode them back, and assert structural equality. They don't hit a
// real worker (that's the integration suite) but they confirm:
//   • Codegen produced types match the discriminator union
//   • Required vs. optional field semantics work
//   • The discriminator field survives both directions
//   • Custom JSON Codable in QVACRequest/QVACResponse correctly routes on `type`

import XCTest
@testable import QVACClient

final class PublicAPISmokeTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder.qvac.encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Single-shot request envelopes

    func test_heartbeat_request_envelope_round_trip() throws {
        let req = QVACRequest.heartbeat(HeartbeatRequest())
        XCTAssertEqual(try roundTrip(req).discriminator, "heartbeat")
    }

    func test_cancel_request_carries_operation_specific_fields() throws {
        var req = CancelRequest(operation: "inference")
        req.modelId = "model-x"
        let envelope = QVACRequest.cancel(req)
        let json = try JSONEncoder.qvac.encode(envelope)
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "cancel")
        XCTAssertEqual(obj?["operation"] as? String, "inference")
        XCTAssertEqual(obj?["modelId"] as? String, "model-x")
    }

    func test_embed_request_carries_text_payload() throws {
        let req = EmbedRequest(modelId: "m", text: .string("hello"))
        let json = try JSONEncoder.qvac.encode(QVACRequest.embed(req))
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "embed")
        XCTAssertEqual(obj?["text"] as? String, "hello")
    }

    func test_unloadModel_request_round_trip() throws {
        var req = UnloadModelRequest(modelId: "m")
        req.clearStorage = true
        let env = QVACRequest.unloadModel(req)
        let decoded = try roundTrip(env)
        XCTAssertEqual(decoded.discriminator, "unloadModel")
        guard case .unloadModel(let r) = decoded else { return XCTFail() }
        XCTAssertEqual(r.modelId, "m")
        XCTAssertEqual(r.clearStorage, true)
    }

    // MARK: - Streaming requests

    func test_completion_request_has_required_fields() throws {
        let req = CompletionStreamRequest(
            history: [.object(["role": .string("user"), "content": .string("hi")])],
            modelId: "m",
            stream: true
        )
        let env = QVACRequest.completionStream(req)
        let decoded = try roundTrip(env)
        guard case .completionStream(let r) = decoded else { return XCTFail() }
        XCTAssertEqual(r.modelId, "m")
        XCTAssertEqual(r.stream, true)
        XCTAssertEqual(r.history.count, 1)
    }

    func test_transcribe_request_supports_filepath_form() throws {
        let req = TranscribeRequest(
            audioChunk: .object(["type": .string("filePath"), "value": .string("/tmp/a.wav")]),
            modelId: "m"
        )
        let env = QVACRequest.transcribe(req)
        let decoded = try roundTrip(env)
        guard case .transcribe(let r) = decoded else { return XCTFail() }
        XCTAssertEqual(r.modelId, "m")
        if case .object(let obj) = r.audioChunk {
            if case .string(let t) = obj["type"] ?? .null { XCTAssertEqual(t, "filePath") }
            else { XCTFail("audioChunk.type missing") }
        } else {
            XCTFail("audioChunk not an object")
        }
    }

    func test_translate_request_supports_both_modes() throws {
        let llmReq = TranslateRequest(
            modelId: "m", modelType: "llamacpp-completion",
            stream: true, text: "hello", to: "fr"
        )
        let env = QVACRequest.translate(llmReq)
        guard case .translate(let r) = try roundTrip(env) else { return XCTFail() }
        XCTAssertEqual(r.modelType, "llamacpp-completion")
        XCTAssertEqual(r.to, "fr")

        let nmtReq = TranslateRequest(
            modelId: "n", modelType: "nmtcpp-translation",
            stream: true, text: "hello", from: "en", to: "es"
        )
        guard case .translate(let n) = try roundTrip(QVACRequest.translate(nmtReq)) else { return XCTFail() }
        XCTAssertEqual(n.modelType, "nmtcpp-translation")
    }

    func test_diffusion_request_carries_optional_params() throws {
        var req = DiffusionStreamRequest(modelId: "sd", prompt: "a cat")
        req.steps = 30
        req.cfgScale = 7.5
        req.width = 512
        req.height = 512
        req.batchCount = 1
        let env = QVACRequest.diffusionStream(req)
        guard case .diffusionStream(let r) = try roundTrip(env) else { return XCTFail() }
        XCTAssertEqual(r.steps, 30)
        XCTAssertEqual(r.cfgScale, 7.5)
        XCTAssertEqual(r.width, 512)
    }

    func test_ocr_request_supports_bytes_form() throws {
        let bytes = Data([0xff, 0xd8, 0xff, 0xe0]) // JPEG header
        let req = OcrStreamRequest(
            image: .object(["type": .string("base64"), "value": .string(bytes.base64EncodedString())]),
            modelId: "m"
        )
        let env = QVACRequest.ocrStream(req)
        guard case .ocrStream(let r) = try roundTrip(env) else { return XCTFail() }
        XCTAssertEqual(r.modelId, "m")
        if case .object(let obj) = r.image, case .string(let s) = obj["value"] ?? .null {
            XCTAssertEqual(s, bytes.base64EncodedString())
        } else {
            XCTFail("image not preserved")
        }
    }

    // MARK: - Response decode

    func test_loadModel_response_with_modelId_decodes() throws {
        let json = #"{"type":"loadModel","success":true,"modelId":"m-1"}"#
        let resp = try JSONDecoder().decode(QVACResponse.self, from: Data(json.utf8))
        guard case .loadModel(let r) = resp else { return XCTFail() }
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.modelId, "m-1")
    }

    func test_unknown_response_type_falls_through_to_unknown_case() throws {
        let json = #"{"type":"futureMessageType","field":42}"#
        let resp = try JSONDecoder().decode(QVACResponse.self, from: Data(json.utf8))
        guard case .unknown(let type, _) = resp else { return XCTFail("expected unknown") }
        XCTAssertEqual(type, "futureMessageType")
    }

    // MARK: - JSONValue Codable

    func test_jsonvalue_round_trip_all_primitives() throws {
        let inputs: [JSONValue] = [
            .null,
            .bool(true),
            .bool(false),
            .number(3.14),
            .number(-1),
            .string(""),
            .string("hello"),
            .array([.string("a"), .number(1)]),
            .object(["k": .string("v"), "n": .number(2)]),
        ]
        for input in inputs {
            let data = try JSONEncoder.qvac.encode(input)
            let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
            XCTAssertEqual(decoded, input)
        }
    }
}
