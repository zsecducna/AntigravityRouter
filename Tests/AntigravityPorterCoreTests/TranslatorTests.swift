import XCTest
@testable import AntigravityPorterCore

final class TranslatorTests: XCTestCase {
    func testGeminiBodyMapsToOpenAIChatCompletionsPayload() throws {
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
        let metadata = ModelRequestMetadata(client: .geminiCLI, model: "gemini-2.5-pro", action: .streamGenerateContent)

        let result = Translator().translate(metadata: metadata, body: body, endpoint: .chatCompletions)

        guard case let .success(payload) = result else {
            return XCTFail("expected translation success, got \(result)")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(payload.endpoint, .chatCompletions)
        XCTAssertEqual(json["model"] as? String, "gemini-2.5-pro")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 8192)
        XCTAssertEqual(messages, [
            ["role": "system", "content": "be concise"],
            ["role": "user", "content": "hello"],
            ["role": "assistant", "content": "hi"]
        ])
    }

    func testGeminiBodyMapsToAnthropicMessagesPayloadForClaude() throws {
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

    func testUnsupportedSchemaFailsClosedInsteadOfForwardingRawBody() throws {
        let metadata = ModelRequestMetadata(client: .antigravity, model: "claude-sonnet-4", action: .generateContent)

        let result = Translator().translate(metadata: metadata, body: Data(#"{"model":"claude-sonnet-4"}"#.utf8), endpoint: .messages)

        XCTAssertEqual(result, .failClosed(reason: .unsupportedSchema))
    }

    func testResponsesEndpointRemainsCaptureDrivenAndFailsClosed() throws {
        let body = Data(#"{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}"#.utf8)
        let metadata = ModelRequestMetadata(client: .geminiCLI, model: "gpt-5.5", action: .generateContent)

        let result = Translator().translate(metadata: metadata, body: body, endpoint: .responses)

        XCTAssertEqual(result, .failClosed(reason: .unsupportedSchema))
    }
}
