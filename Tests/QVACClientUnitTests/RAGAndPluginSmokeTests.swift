// RAG + plugin invocation smoke tests — wire-shape only, no live worker.

import XCTest
@testable import QVACClient

final class RAGAndPluginSmokeTests: XCTestCase {

    private func wirePayload<T: Encodable>(_ v: T) throws -> [String: Any] {
        let data = try JSONEncoder.qvac.encode(v)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: - RAG envelopes

    func test_ragIngest_envelope_carries_operation_and_documents() throws {
        var req = RagRequest(operation: "ingest")
        req.modelId = "m"
        req.documents = .array([.string("doc1"), .string("doc2")])
        let envelope = QVACRequest.rag(req)
        let obj = try wirePayload(envelope)
        XCTAssertEqual(obj["type"] as? String, "rag")
        XCTAssertEqual(obj["operation"] as? String, "ingest")
        XCTAssertEqual(obj["modelId"] as? String, "m")
        XCTAssertEqual((obj["documents"] as? [String])?.count, 2)
    }

    func test_ragSearch_envelope_includes_query_and_topK() throws {
        var req = RagRequest(operation: "search")
        req.modelId = "m"
        req.query = "what is rag"
        req.topK = 5
        let obj = try wirePayload(QVACRequest.rag(req))
        XCTAssertEqual(obj["operation"] as? String, "search")
        XCTAssertEqual(obj["query"] as? String, "what is rag")
        XCTAssertEqual(obj["topK"] as? Double, 5)
    }

    func test_ragDeleteWorkspace_required_fields() throws {
        var req = RagRequest(operation: "deleteWorkspace")
        req.workspace = "ws1"
        let obj = try wirePayload(QVACRequest.rag(req))
        XCTAssertEqual(obj["workspace"] as? String, "ws1")
    }

    func test_ragListWorkspaces_minimal_envelope() throws {
        let obj = try wirePayload(QVACRequest.rag(RagRequest(operation: "listWorkspaces")))
        XCTAssertEqual(obj["type"] as? String, "rag")
        XCTAssertEqual(obj["operation"] as? String, "listWorkspaces")
    }

    func test_ragResponse_decode_with_results() throws {
        let json = #"""
        {"type":"rag","operation":"search","success":true,"results":[
            {"id":"d1","text":"hello","score":0.9,"metadata":{"src":"a.txt"}}
        ]}
        """#
        let resp = try JSONDecoder().decode(QVACResponse.self, from: Data(json.utf8))
        guard case .rag(let r) = resp else { return XCTFail() }
        XCTAssertEqual(r.operation, "search")
        XCTAssertEqual(r.results?.count, 1)
    }

    // MARK: - Plugin invocation

    struct DummyPluginParams: Codable, Equatable {
        let prompt: String
        let n: Int
    }
    struct DummyPluginResult: Codable, Equatable {
        let text: String
    }

    func test_invokePlugin_envelope_carries_params() throws {
        let req = PluginInvokeRequest(
            handler: "myHandler",
            modelId: "m",
            params: try QVACClient.encodeAsJSONValue(DummyPluginParams(prompt: "hi", n: 3))
        )
        let obj = try wirePayload(QVACRequest.pluginInvoke(req))
        XCTAssertEqual(obj["type"] as? String, "pluginInvoke")
        XCTAssertEqual(obj["handler"] as? String, "myHandler")
        XCTAssertEqual(obj["modelId"] as? String, "m")
        guard let params = obj["params"] as? [String: Any] else { return XCTFail("params not an object") }
        XCTAssertEqual(params["prompt"] as? String, "hi")
        XCTAssertEqual(params["n"] as? Int, 3)
    }

    func test_invokePluginStream_response_with_done_flag() throws {
        let json = #"{"type":"pluginInvokeStream","result":{"text":"chunk 1"},"done":false}"#
        let resp = try JSONDecoder().decode(QVACResponse.self, from: Data(json.utf8))
        guard case .pluginInvokeStream(let r) = resp else { return XCTFail() }
        XCTAssertEqual(r.done, false)
        if case .object(let obj) = r.result, case .string(let t) = obj["text"] ?? .null {
            XCTAssertEqual(t, "chunk 1")
        } else { XCTFail() }
    }

    func test_jsonvalue_encoder_decoder_round_trip() throws {
        let original = DummyPluginParams(prompt: "test", n: 42)
        let asJSONValue = try QVACClient.encodeAsJSONValue(original)
        let decoded = try QVACClient.decodeFromJSONValue(asJSONValue, as: DummyPluginParams.self)
        XCTAssertEqual(decoded, original)
    }
}
