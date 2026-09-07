import XCTest
@testable import QVACClient

/// Exhaustive validation tests for the hand-written completion adapter.
///
/// These fixtures intentionally exercise malformed worker values in addition to
/// successful events. The generated Codable layer proves that JSON is syntactically
/// valid; this suite proves that the richer public API rejects values that violate
/// the pinned 0.17 semantic contract.
final class QVACCompletionValidationCoverageTests: XCTestCase {
    private func assertProtocolViolation<T>(
        _ expression: @autoclosure () throws -> T,
        contains expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case .protocolViolation(let message) = error as? QVACError else {
                return XCTFail("expected protocol violation, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                message.contains(expectedText),
                "expected diagnostic containing '\(expectedText)', got '\(message)'",
                file: file,
                line: line
            )
        }
    }

    private func assertInvalidArgument(
        _ responseFormat: JSONValue?,
        hasTools: Bool = false,
        contains expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try QVACClient.validateCompletionResponseFormat(
                responseFormat,
                hasTools: hasTools,
                context: "completion"
            ),
            file: file,
            line: line
        ) { error in
            guard case .invalidArgument(let message) = error as? QVACError else {
                return XCTFail("expected invalid argument, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                message.contains(expectedText),
                "expected diagnostic containing '\(expectedText)', got '\(message)'",
                file: file,
                line: line
            )
        }
    }

    func test_chat_message_factories_preserve_roles_attachments_and_cache_normalization() {
        let attachment = QVACClient.ChatAttachment(path: "/models/image.png")
        XCTAssertEqual(
            QVACClient.ChatMessage.assistant("answer", attachments: [attachment]),
            .init(role: "assistant", content: "answer", attachments: [attachment])
        )
        XCTAssertEqual(
            QVACClient.ChatMessage.system("policy"),
            .init(role: "system", content: "policy")
        )
        XCTAssertEqual(
            QVACClient.normalizeAssistantCacheContent(
                "  <think>private reasoning</think> Public answer.  \n"
            ),
            "Public answer."
        )
        XCTAssertEqual(
            QVACClient.normalizeAssistantCacheContent("visible <think>unfinished"),
            "visible"
        )
    }

    func test_completion_stats_accept_every_017_field_and_reject_invalid_shapes() throws {
        let stats = try QVACClient.CompletionStats(wire: .object([
            "timeToFirstToken": .number(1),
            "tokensPerSecond": .number(2),
            "cacheTokens": .number(3),
            "promptTokens": .number(4),
            "generatedTokens": .number(5),
            "emittedTokens": .number(6),
            "avgConcurrentSeq": .number(7),
            "backendDevice": .string("cpu"),
        ]))
        XCTAssertEqual(stats.timeToFirstToken, 1)
        XCTAssertEqual(stats.tokensPerSecond, 2)
        XCTAssertEqual(stats.cacheTokens, 3)
        XCTAssertEqual(stats.promptTokens, 4)
        XCTAssertEqual(stats.generatedTokens, 5)
        XCTAssertEqual(stats.emittedTokens, 6)
        XCTAssertEqual(stats.avgConcurrentSeq, 7)
        XCTAssertEqual(stats.backendDevice, .cpu)

        let empty = try QVACClient.CompletionStats(wire: .object([:]))
        XCTAssertNil(empty.backendDevice)
        assertProtocolViolation(
            try QVACClient.CompletionStats(wire: .array([])),
            contains: "must be an object"
        )
        assertProtocolViolation(
            try QVACClient.CompletionStats(wire: .object(["promptTokens": .string("4")])),
            contains: "promptTokens must be a number"
        )
        assertProtocolViolation(
            try QVACClient.CompletionStats(wire: .object(["backendDevice": .string("npu")])),
            contains: "must be cpu or gpu"
        )
    }

    func test_completion_tool_payloads_validate_required_and_optional_fields() throws {
        let call = try QVACClient.CompletionToolCall(wire: .object([
            "id": .string("call-1"),
            "name": .string("weather"),
            "arguments": .object(["city": .string("Delhi")]),
        ]))
        XCTAssertEqual(call.id, "call-1")
        XCTAssertEqual(call.name, "weather")
        XCTAssertEqual(call.arguments, ["city": .string("Delhi")])
        XCTAssertNil(call.raw)

        let rawCall = try QVACClient.CompletionToolCall(wire: .object([
            "id": .string("call-2"),
            "name": .string("clock"),
            "arguments": .object([:]),
            "raw": .string("<tool>"),
        ]))
        XCTAssertEqual(rawCall.raw, "<tool>")

        assertProtocolViolation(
            try QVACClient.CompletionToolCall(wire: .object([
                "id": .string("call-3"),
                "name": .string("weather"),
                "arguments": .array([]),
            ])),
            contains: "invalid shape"
        )
        assertProtocolViolation(
            try QVACClient.CompletionToolCall(wire: .object([
                "id": .string("call-4"),
                "name": .string("weather"),
                "arguments": .object([:]),
                "raw": .number(1),
            ])),
            contains: "raw must be a string"
        )

        let toolError = try QVACClient.CompletionToolError(wire: .object([
            "code": .string("UNKNOWN_TOOL"),
            "message": .string("No such tool"),
            "raw": .string("unknown()"),
        ]))
        XCTAssertEqual(toolError.code, .unknownTool)
        XCTAssertEqual(toolError.message, "No such tool")
        XCTAssertEqual(toolError.raw, "unknown()")

        let errorWithoutRaw = try QVACClient.CompletionToolError(wire: .object([
            "code": .string("PARSE_ERROR"),
            "message": .string("Malformed call"),
        ]))
        XCTAssertNil(errorWithoutRaw.raw)
        assertProtocolViolation(
            try QVACClient.CompletionToolError(wire: .object([
                "code": .string("FUTURE_ERROR"),
                "message": .string("Unsupported"),
            ])),
            contains: "invalid shape"
        )
        assertProtocolViolation(
            try QVACClient.CompletionToolError(wire: .object([
                "code": .string("VALIDATION_ERROR"),
                "message": .string("Invalid"),
                "raw": .bool(true),
            ])),
            contains: "raw must be a string"
        )
    }

    func test_completion_events_decode_all_semantic_variants() throws {
        let fixtures: [(JSONValue, QVACClient.CompletionEvent)] = [
            (
                .object(["type": .string("contentDelta"), "seq": .number(0), "text": .string("a")]),
                .contentDelta(seq: 0, text: "a")
            ),
            (
                .object(["type": .string("rawDelta"), "seq": .number(1), "text": .string("<a>")]),
                .rawDelta(seq: 1, text: "<a>")
            ),
            (
                .object(["type": .string("thinkingDelta"), "seq": .number(2), "text": .string("r")]),
                .thinkingDelta(seq: 2, text: "r")
            ),
            (
                .object([
                    "type": .string("toolError"),
                    "seq": .number(3),
                    "error": .object([
                        "code": .string("VALIDATION_ERROR"),
                        "message": .string("bad arguments"),
                    ]),
                ]),
                .toolError(
                    seq: 3,
                    error: try .init(wire: .object([
                        "code": .string("VALIDATION_ERROR"),
                        "message": .string("bad arguments"),
                    ]))
                )
            ),
            (
                .object([
                    "type": .string("completionDone"),
                    "seq": .number(4),
                    "stopReason": .string("error"),
                    "error": .object(["message": .string("backend failed")]),
                    "raw": .object(["fullText": .string("partial")]),
                ]),
                .failure(seq: 4, message: "backend failed", rawFullText: "partial")
            ),
            (
                .object(["type": .string("completionDone"), "seq": .number(5)]),
                .done(seq: 5, stopReason: nil, rawFullText: nil)
            ),
        ]

        for (wire, expected) in fixtures {
            XCTAssertEqual(try QVACClient.CompletionEvent(wire: wire), expected)
        }
    }

    func test_completion_events_reject_each_malformed_contract_shape() {
        let malformed: [(wire: JSONValue, diagnostic: String)] = [
            (.object(["type": .string("contentDelta")]), "non-negative integer seq"),
            (
                .object(["type": .string("contentDelta"), "seq": .number(-1), "text": .string("x")]),
                "non-negative integer seq"
            ),
            (
                .object(["type": .string("contentDelta"), "seq": .number(0), "text": .number(1)]),
                "contentDelta.text"
            ),
            (
                .object(["type": .string("rawDelta"), "seq": .number(0), "text": .bool(true)]),
                "rawDelta.text"
            ),
            (
                .object(["type": .string("thinkingDelta"), "seq": .number(0), "text": .null]),
                "thinkingDelta.text"
            ),
            (
                .object([
                    "type": .string("completionDone"),
                    "seq": .number(0),
                    "stopReason": .string("error"),
                ]),
                "requires error.message"
            ),
            (
                .object([
                    "type": .string("completionDone"),
                    "seq": .number(0),
                    "stopReason": .string("future"),
                ]),
                "not a 0.17 value"
            ),
            (
                .object([
                    "type": .string("completionDone"),
                    "seq": .number(0),
                    "raw": .object(["fullText": .number(1)]),
                ]),
                "raw.fullText"
            ),
            (
                .object(["type": .string("futureEvent"), "seq": .number(0)]),
                "unknown 0.17 completion event"
            ),
        ]

        for fixture in malformed {
            assertProtocolViolation(
                try QVACClient.CompletionEvent(wire: fixture.wire),
                contains: fixture.diagnostic
            )
        }
    }

    func test_completion_response_format_validation_covers_the_full_017_union() throws {
        try QVACClient.validateCompletionResponseFormat(nil, hasTools: false, context: "completion")
        try QVACClient.validateCompletionResponseFormat(
            .object(["type": .string("text")]),
            hasTools: true,
            context: "completion"
        )
        try QVACClient.validateCompletionResponseFormat(
            .object(["type": .string("json_object")]),
            hasTools: false,
            context: "completion"
        )
        try QVACClient.validateCompletionResponseFormat(
            .object([
                "type": .string("json_schema"),
                "json_schema": .object([
                    "name": .string("answer"),
                    "description": .string("Structured answer"),
                    "schema": .object(["type": .string("object")]),
                    "strict": .bool(true),
                ]),
            ]),
            hasTools: false,
            context: "completion"
        )

        let malformed: [(JSONValue, Bool, String)] = [
            (.string("text"), false, "object with a string type"),
            (
                .object(["type": .string("text"), "extra": .bool(true)]),
                false,
                "does not accept extra fields"
            ),
            (
                .object(["type": .string("json_schema"), "json_schema": .object([:])]),
                false,
                "invalid shape"
            ),
            (
                .object([
                    "type": .string("json_schema"),
                    "json_schema": .object([
                        "name": .string("answer"),
                        "description": .number(1),
                        "schema": .object([:]),
                    ]),
                ]),
                false,
                "description must be a string"
            ),
            (
                .object([
                    "type": .string("json_schema"),
                    "json_schema": .object([
                        "name": .string("answer"),
                        "schema": .object([:]),
                        "strict": .string("true"),
                    ]),
                ]),
                false,
                "strict must be a boolean"
            ),
            (.object(["type": .string("xml")]), false, "text, json_object, or json_schema"),
            (
                .object(["type": .string("json_object")]),
                true,
                "cannot be combined with tools"
            ),
        ]
        for (responseFormat, hasTools, diagnostic) in malformed {
            assertInvalidArgument(
                responseFormat,
                hasTools: hasTools,
                contains: diagnostic
            )
        }
    }
}
