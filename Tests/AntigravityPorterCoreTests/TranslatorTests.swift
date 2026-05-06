import XCTest
@testable import AntigravityPorterCore

final class TranslatorTests: XCTestCase {
    func testAntigravityBodyMapsToOpenAIChatCompletionsPayload() throws {
        let body = Data("""
        {
          "systemInstruction": {"parts": [{"text": "be concise"}]},
          "contents": [
            {"role": "user", "parts": [{"text": "hello"}]},
            {"role": "model", "parts": [{"text": "hi"}]}
          ],
          "generationConfig": {"temperature": 1.0, "maxOutputTokens": 8192}
        }
        """.utf8)
        let metadata = ModelRequestMetadata(client: .antigravity, model: "gpt-5.5", action: .streamGenerateContent)

        let result = Translator().translate(metadata: metadata, body: body, endpoint: .chatCompletions)

        guard case let .success(payload) = result else {
            return XCTFail("expected translation success, got \(result)")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(payload.endpoint, .chatCompletions)
        XCTAssertEqual(json["model"] as? String, "gpt-5.5")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 8192)
        XCTAssertEqual(messages, [
            ["role": "system", "content": "be concise"],
            ["role": "user", "content": "hello"],
            ["role": "assistant", "content": "hi"]
        ])
    }

    func testAntigravityBodyMapsToAnthropicMessagesPayloadForClaude() throws {
        let body = Data("""
        {
          "systemInstruction": {"parts": [{"text": "be exact"}]},
          "contents": [
            {"role": "user", "parts": [{"text": "hello"}]}
          ],
          "generationConfig": {"temperature": 0.2, "maxOutputTokens": 4096}
        }
        """.utf8)
        let metadata = ModelRequestMetadata(client: .antigravity, model: "claude-sonnet-4", action: .generateContent)

        let result = Translator().translate(metadata: metadata, body: body, endpoint: .messages)

        guard case let .success(payload) = result else {
            return XCTFail("expected translation success, got \(result)")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(payload.endpoint, .messages)
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-4")
        XCTAssertEqual(json["system"] as? String, "be exact")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertEqual(messages, [["role": "user", "content": "hello"]])
    }

    func testAntigravityNestedRequestMapsToAnthropicMessagesPayload() throws {
        let body = Data("""
        {
          "model": "claude-sonnet-4-6",
          "userAgent": "antigravity",
          "request": {
            "systemInstruction": {"parts": [{"text": "be exact"}]},
            "contents": [
              {"role": "user", "parts": [{"text": "hello"}]}
            ],
            "generationConfig": {"maxOutputTokens": 4096}
          }
        }
        """.utf8)
        let metadata = ModelRequestMetadata(client: .antigravity, model: "claude-sonnet-4-6", action: .streamGenerateContent)

        let result = Translator().translate(metadata: metadata, body: body, endpoint: .messages)

        guard case let .success(payload) = result else {
            return XCTFail("expected translation success, got \(result)")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertEqual(messages, [["role": "user", "content": "hello"]])
    }

    func testAntigravityNestedClaudeRequestDefaultsMaxTokensWhenMissing() throws {
        let body = Data("""
        {
          "model": "claude-sonnet-4-6",
          "request": {
            "contents": [
              {"role": "user", "parts": [{"text": "hello"}]}
            ]
          }
        }
        """.utf8)
        let metadata = ModelRequestMetadata(client: .antigravity, model: "claude-sonnet-4-6", action: .streamGenerateContent)

        let result = Translator().translate(metadata: metadata, body: body, endpoint: .messages)

        guard case let .success(payload) = result else {
            return XCTFail("expected translation success, got \(result)")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testUnsupportedSchemaFailsClosedInsteadOfForwardingRawBody() throws {
        let metadata = ModelRequestMetadata(client: .antigravity, model: "claude-sonnet-4", action: .generateContent)

        let result = Translator().translate(metadata: metadata, body: Data(#"{"model":"claude-sonnet-4"}"#.utf8), endpoint: .messages)

        XCTAssertEqual(result, .failClosed(reason: .unsupportedSchema))
    }

    func testResponsesEndpointRemainsCaptureDrivenAndFailsClosed() throws {
        let body = Data(#"{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}"#.utf8)
        let metadata = ModelRequestMetadata(client: .antigravity, model: "gpt-5.5", action: .generateContent)

        let result = Translator().translate(metadata: metadata, body: body, endpoint: .responses)

        XCTAssertEqual(result, .failClosed(reason: .unsupportedSchema))
    }

    func testOpenAISSEMapsToGoogleGenerateContentSSE() throws {
        let response = CheapRouterResponse(
            statusCode: 200,
            headers: ["content-type": "text/event-stream"],
            body: Data("""
            data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}

            data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3},"model":"gpt-5.5"}

            data: [DONE]

            """.utf8)
        )
        let metadata = ModelRequestMetadata(client: .antigravity, model: "gpt-5.5", action: .streamGenerateContent)

        let translated = ResponseTranslator().translate(response: response, metadata: metadata)
        let text = String(decoding: translated.body, as: UTF8.self)

        XCTAssertEqual(translated.headers["content-type"], "text/event-stream")
        XCTAssertTrue(text.contains(#""response":{"#))
        XCTAssertTrue(text.contains(#""responseId":"resp_"#))
        XCTAssertTrue(text.contains(#""text":"Hi""#))
        XCTAssertTrue(text.contains(#""finishReason":"STOP""#))
        XCTAssertTrue(text.contains(#""totalTokenCount":3"#))
        XCTAssertTrue(text.contains("data: [DONE]"))
    }

    func testAnthropicJSONMapsToGoogleGenerateContentJSON() throws {
        let response = CheapRouterResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data("""
            {
              "model": "claude-sonnet-4-6",
              "content": [{"type": "text", "text": "Hello"}],
              "stop_reason": "end_turn",
              "usage": {"input_tokens": 4, "output_tokens": 2}
            }
            """.utf8)
        )
        let metadata = ModelRequestMetadata(client: .antigravity, model: "claude-sonnet-4-6", action: .generateContent)

        let translated = ResponseTranslator().translate(response: response, metadata: metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: translated.body) as? [String: Any])
        let candidates = try XCTUnwrap(json["candidates"] as? [[String: Any]])
        let content = try XCTUnwrap(candidates.first?["content"] as? [String: Any])
        let parts = try XCTUnwrap(content["parts"] as? [[String: String]])

        XCTAssertEqual(parts.first?["text"], "Hello")
        XCTAssertEqual(json["modelVersion"] as? String, "claude-sonnet-4-6")
    }

}
