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

    func testAntigravityBodyMapsToOpenAIResponsesPayload() throws {
        let body = Data("""
        {
          "systemInstruction": {"parts": [{"text": "be concise"}]},
          "contents": [
            {"role": "user", "parts": [{"text": "hi"}]},
            {"role": "model", "parts": [{"text": "hello"}]}
          ],
          "tools": [{
            "functionDeclarations": [{
              "name": "read_file",
              "description": "Read a file",
              "parameters": {"type": "OBJECT", "properties": {"path": {"type": "STRING"}}}
            }]
          }],
          "generationConfig": {"temperature": 0.4, "maxOutputTokens": 512}
        }
        """.utf8)
        let metadata = ModelRequestMetadata(client: .antigravity, model: "gpt-5.5", action: .generateContent)

        let result = Translator().translate(metadata: metadata, body: body, endpoint: .responses)

        guard case let .success(payload) = result else {
            return XCTFail("expected translation success, got \(result)")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
        let input = try XCTUnwrap(json["input"] as? [[String: String]])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let parameters = try XCTUnwrap(tools.first?["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let path = try XCTUnwrap(properties["path"] as? [String: Any])

        XCTAssertEqual(payload.endpoint, .responses)
        XCTAssertEqual(json["model"] as? String, "gpt-5.5")
        XCTAssertEqual(json["instructions"] as? String, "be concise")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["temperature"] as? Double, 0.4)
        XCTAssertEqual(json["max_output_tokens"] as? Int, 512)
        XCTAssertEqual(input, [
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": "hello"]
        ])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertEqual(tools.first?["name"] as? String, "read_file")
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertEqual(path["type"] as? String, "string")
    }

    func testAntigravityFunctionResponseMapsToOpenAIResponsesInput() throws {
        let body = Data("""
        {
          "contents": [{
            "role": "user",
            "parts": [{
              "functionResponse": {
                "name": "read_file",
                "id": "call_123",
                "response": {"content": "file text"}
              }
            }]
          }]
        }
        """.utf8)
        let metadata = ModelRequestMetadata(client: .antigravity, model: "gpt-5.5", action: .generateContent)

        let result = Translator().translate(metadata: metadata, body: body, endpoint: .responses)

        guard case let .success(payload) = result else {
            return XCTFail("expected translation success, got \(result)")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        let output = try XCTUnwrap(input.first)

        XCTAssertEqual(output["type"] as? String, "function_call_output")
        XCTAssertEqual(output["call_id"] as? String, "call_123")
        XCTAssertEqual(output["output"] as? String, #"{"content":"file text"}"#)
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

    func testOpenAIResponsesSSEMapsToGoogleGenerateContentSSE() throws {
        let response = CheapRouterResponse(
            statusCode: 200,
            headers: ["content-type": "text/event-stream"],
            body: Data("""
            data: {"type":"response.output_text.delta","delta":"Hi"}

            data: {"type":"response.reasoning_text.delta","delta":"thinking"}

            data: {"type":"response.completed","response":{"model":"gpt-5.5","usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3}}}

            data: [DONE]

            """.utf8)
        )
        let metadata = ModelRequestMetadata(client: .antigravity, model: "gpt-5.5", action: .streamGenerateContent)

        let translated = ResponseTranslator().translate(response: response, metadata: metadata)
        let text = String(decoding: translated.body, as: UTF8.self)

        XCTAssertTrue(text.contains(#""text":"Hi""#))
        XCTAssertTrue(text.contains(#""thought":true"#))
        XCTAssertTrue(text.contains(#""text":"thinking""#))
        XCTAssertTrue(text.contains(#""finishReason":"STOP""#))
        XCTAssertTrue(text.contains(#""totalTokenCount":3"#))
    }

    func testOpenAIResponsesJSONMapsToGoogleGenerateContentJSON() throws {
        let response = CheapRouterResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data("""
            {
              "object": "response",
              "model": "gpt-5.5",
              "output_text": "Hello",
              "usage": {"input_tokens": 4, "output_tokens": 2, "total_tokens": 6}
            }
            """.utf8)
        )
        let metadata = ModelRequestMetadata(client: .antigravity, model: "gpt-5.5", action: .generateContent)

        let translated = ResponseTranslator().translate(response: response, metadata: metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: translated.body) as? [String: Any])
        let candidates = try XCTUnwrap(json["candidates"] as? [[String: Any]])
        let content = try XCTUnwrap(candidates.first?["content"] as? [String: Any])
        let parts = try XCTUnwrap(content["parts"] as? [[String: String]])
        let usage = try XCTUnwrap(json["usageMetadata"] as? [String: Any])

        XCTAssertEqual(parts.first?["text"], "Hello")
        XCTAssertEqual(json["modelVersion"] as? String, "gpt-5.5")
        XCTAssertEqual(usage["totalTokenCount"] as? Int, 6)
    }

    func testOpenAIResponsesFunctionCallMapsToGoogleFunctionCallJSON() throws {
        let response = CheapRouterResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data("""
            {
              "object": "response",
              "model": "gpt-5.5",
              "output": [{
                "type": "function_call",
                "call_id": "call_123",
                "name": "read_file",
                "arguments": "{\\"path\\":\\"/tmp/a.txt\\"}"
              }]
            }
            """.utf8)
        )
        let metadata = ModelRequestMetadata(client: .antigravity, model: "gpt-5.5", action: .generateContent)

        let translated = ResponseTranslator().translate(response: response, metadata: metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: translated.body) as? [String: Any])
        let candidates = try XCTUnwrap(json["candidates"] as? [[String: Any]])
        let content = try XCTUnwrap(candidates.first?["content"] as? [String: Any])
        let parts = try XCTUnwrap(content["parts"] as? [[String: Any]])
        let part = try XCTUnwrap(parts.first)
        let functionCall = try XCTUnwrap(part["functionCall"] as? [String: Any])
        let args = try XCTUnwrap(functionCall["args"] as? [String: Any])

        XCTAssertEqual(functionCall["name"] as? String, "read_file")
        XCTAssertEqual(functionCall["id"] as? String, "call_123")
        XCTAssertEqual(args["path"] as? String, "/tmp/a.txt")
    }

    func testOpenAIResponsesMultipleFunctionCallsMapToOneGoogleCandidate() throws {
        let response = CheapRouterResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data("""
            {
              "object": "response",
              "model": "gpt-5.5",
              "output": [
                {"type": "function_call", "call_id": "call_1", "name": "read_file", "arguments": "{\\"path\\":\\"/tmp/a.txt\\"}"},
                {"type": "function_call", "call_id": "call_2", "name": "write_file", "arguments": "{\\"path\\":\\"/tmp/b.txt\\"}"}
              ]
            }
            """.utf8)
        )
        let metadata = ModelRequestMetadata(client: .antigravity, model: "gpt-5.5", action: .generateContent)

        let translated = ResponseTranslator().translate(response: response, metadata: metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: translated.body) as? [String: Any])
        let candidates = try XCTUnwrap(json["candidates"] as? [[String: Any]])
        let content = try XCTUnwrap(candidates.first?["content"] as? [String: Any])
        let parts = try XCTUnwrap(content["parts"] as? [[String: Any]])
        let names = parts.compactMap { ($0["functionCall"] as? [String: Any])?["name"] as? String }

        XCTAssertEqual(names, ["read_file", "write_file"])
    }

    func testOpenAIResponsesFunctionCallMapsToGoogleFunctionCallSSE() throws {
        let response = CheapRouterResponse(
            statusCode: 200,
            headers: ["content-type": "text/event-stream"],
            body: Data("""
            data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_123","name":"read_file","arguments":"{\\"path\\":\\"/tmp/a.txt\\"}"}}

            data: [DONE]

            """.utf8)
        )
        let metadata = ModelRequestMetadata(client: .antigravity, model: "gpt-5.5", action: .streamGenerateContent)

        let translated = ResponseTranslator().translate(response: response, metadata: metadata)
        let text = String(decoding: translated.body, as: UTF8.self)

        XCTAssertTrue(text.contains(#""functionCall":{"#))
        XCTAssertTrue(text.contains(#""name":"read_file""#))
        XCTAssertTrue(text.contains(#""id":"call_123""#))
    }

    func testInjectsProviderModelsIntoAntigravityAvailableModelsCatalog() throws {
        let body = Data("""
        {
          "models": {
            "gemini-3-flash": {
              "displayName": "Gemini 3 Flash",
              "maxTokens": 1000,
              "model": "MODEL_PLACEHOLDER_M37"
            },
            "gemini-reserved": {
              "displayName": "Gemini Reserved",
              "model": "MODEL_PLACEHOLDER_M100"
            }
          },
          "defaultAgentModelId": "gemini-3-flash",
          "agentModelSorts": [{
            "displayName": "Recommended",
            "groups": [{"modelIds": ["gemini-3-flash"]}]
          }]
        }
        """.utf8)

        let report = AntigravityModelCatalogInjector.injectProviderModelsWithReport(
            [ProviderModel(id: "gpt-5.5"), ProviderModel(id: "claude-sonnet-4-6")],
            into: body
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: report.body) as? [String: Any])
        let models = try XCTUnwrap(json["models"] as? [String: Any])
        let gpt = try XCTUnwrap(models["gpt-5.5"] as? [String: Any])
        let claude = try XCTUnwrap(models["claude-sonnet-4-6"] as? [String: Any])
        let sorts = try XCTUnwrap(json["agentModelSorts"] as? [[String: Any]])
        let groups = try XCTUnwrap(sorts.first?["groups"] as? [[String: Any]])
        let targetGroup = try XCTUnwrap(groups.last)

        XCTAssertNotNil(models["gemini-3-flash"])
        XCTAssertEqual(gpt["displayName"] as? String, "gpt-5.5")
        XCTAssertEqual(gpt["apiProvider"] as? String, "API_PROVIDER_GOOGLE_GEMINI")
        XCTAssertEqual(gpt["recommended"] as? Bool, true)
        XCTAssertTrue((gpt["model"] as? String)?.hasPrefix("MODEL_PLACEHOLDER_M") == true)
        XCTAssertNotEqual(gpt["model"] as? String, "MODEL_PLACEHOLDER_M37")
        XCTAssertNotEqual(gpt["model"] as? String, "MODEL_PLACEHOLDER_M100")
        XCTAssertNotEqual(gpt["model"] as? String, claude["model"] as? String)
        XCTAssertEqual(report.modelAliases["gpt-5.5"], "gpt-5.5")
        XCTAssertEqual(report.modelAliases[gpt["model"] as? String ?? ""], "gpt-5.5")
        XCTAssertEqual(groups.first?["modelIds"] as? [String], ["gemini-3-flash", "gpt-5.5", "claude-sonnet-4-6"])
        XCTAssertEqual(targetGroup["displayName"] as? String, "Target provider")
        XCTAssertEqual(targetGroup["modelIds"] as? [String], ["gpt-5.5", "claude-sonnet-4-6"])
    }

    func testInjectedProviderModelsUseUniquePlaceholderValuesPastPreferredPool() throws {
        var existing: [String: Any] = [:]
        for index in 0...150 {
            existing["google-\(index)"] = ["model": "MODEL_PLACEHOLDER_M\(index)"]
        }
        let body = try JSONSerialization.data(withJSONObject: ["models": existing], options: [])
        let providerModels = (0..<12).map { ProviderModel(id: "provider/model-\($0)") }

        let report = AntigravityModelCatalogInjector.injectProviderModelsWithReport(providerModels, into: body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: report.body) as? [String: Any])
        let models = try XCTUnwrap(json["models"] as? [String: Any])
        let insertedValues = providerModels.compactMap { id -> String? in
            (models[id.id] as? [String: Any])?["model"] as? String
        }

        XCTAssertEqual(insertedValues.count, providerModels.count)
        XCTAssertEqual(Set(insertedValues).count, providerModels.count)
        XCTAssertTrue(insertedValues.allSatisfy { $0.hasPrefix("MODEL_PLACEHOLDER_M") })
        XCTAssertTrue(insertedValues.allSatisfy { Int($0.replacingOccurrences(of: "MODEL_PLACEHOLDER_M", with: "")) ?? 0 >= 151 })
    }

    func testUnsupportedProviderStreamReturnsBadGatewayInsteadOfEmptyDone() throws {
        let response = CheapRouterResponse(
            statusCode: 200,
            headers: ["content-type": "text/event-stream"],
            body: Data("""
            data: {"type":"unknown.event","delta":"ignored"}

            data: [DONE]

            """.utf8)
        )
        let metadata = ModelRequestMetadata(client: .antigravity, model: "gpt-5.5", action: .streamGenerateContent)

        let translated = ResponseTranslator().translate(response: response, metadata: metadata)
        let text = String(decoding: translated.body, as: UTF8.self)

        XCTAssertEqual(translated.statusCode, 502)
        XCTAssertTrue(text.contains("provider stream response was empty or unsupported"))
        XCTAssertFalse(text.contains("[DONE]"))
    }

}
