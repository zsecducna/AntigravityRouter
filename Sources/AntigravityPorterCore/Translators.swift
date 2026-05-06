import Foundation

public enum PorterClient: Equatable, Sendable {
    case antigravity
}

public enum PorterAction: Equatable, Hashable, Sendable {
    case generateContent
    case streamGenerateContent
    case countTokens
    case unknown(String)
}

public struct ModelRequestMetadata: Equatable, Sendable {
    public var client: PorterClient
    public var model: String
    public var action: PorterAction

    public init(client: PorterClient, model: String, action: PorterAction) {
        self.client = client
        self.model = model
        self.action = action
    }
}

public enum ModelExtractorError: Error, Equatable, Sendable {
    case modelNotFound
}

public enum ModelExtractor {
    public static func extract(host: String, path: String, body: Data) throws -> ModelRequestMetadata {
        let action = actionFromPath(path)
        if let model = modelFromJSON(body) {
            return ModelRequestMetadata(client: .antigravity, model: model, action: action)
        }
        throw ModelExtractorError.modelNotFound
    }

    private static func actionFromPath(_ path: String) -> PorterAction {
        if path.contains(":streamGenerateContent") { return .streamGenerateContent }
        if path.contains(":generateContent") { return .generateContent }
        if path.contains(":countTokens") { return .countTokens }
        return .unknown(path)
    }

    private static func modelFromJSON(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return nil }
        return firstModel(in: object)
    }

    private static func firstModel(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            if let model = object["model"] as? String { return model }
            for child in object.values {
                if let model = firstModel(in: child) { return model }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let model = firstModel(in: child) { return model }
            }
        }
        return nil
    }
}

public enum CheapRouterEndpoint: Equatable, Sendable {
    case chatCompletions
    case messages
    case models
    case responses

    public var path: String {
        switch self {
        case .chatCompletions: "/v1/chat/completions"
        case .messages: "/v1/messages"
        case .models: "/v1/models"
        case .responses: "/v1/responses"
        }
    }
}

public enum RoutingFailureReason: Equatable, Sendable {
    case unsupportedAction
    case unsupportedModel
}

public enum RoutingDecision: Equatable, Sendable {
    case googleDirect
    case cheapRouter(endpoint: CheapRouterEndpoint)
    case failClosed(reason: RoutingFailureReason)
}

public struct RoutingEngineConfiguration: Equatable, Sendable {
    public var customProviderRoutingEnabled: Bool
    public var supportedActions: Set<PorterAction>

    public init(
        customProviderRoutingEnabled: Bool = false,
        supportedActions: Set<PorterAction> = [.generateContent, .streamGenerateContent]
    ) {
        self.customProviderRoutingEnabled = customProviderRoutingEnabled
        self.supportedActions = supportedActions
    }
}

public struct RoutingEngine: Sendable {
    public var config: RoutingEngineConfiguration

    public init(config: RoutingEngineConfiguration) {
        self.config = config
    }

    public func decision(for metadata: ModelRequestMetadata) -> RoutingDecision {
        guard config.customProviderRoutingEnabled else { return .googleDirect }
        guard config.supportedActions.contains(metadata.action) else { return .failClosed(reason: .unsupportedAction) }
        return .cheapRouter(endpoint: metadata.model.lowercased().contains("claude") ? .messages : .chatCompletions)
    }
}

public enum TranslatorFailureReason: Equatable, Sendable {
    case unsupportedAction
    case unsupportedSchema
}

public enum TranslationResult<Success: Equatable & Sendable>: Equatable, Sendable {
    case success(Success)
    case failClosed(reason: TranslatorFailureReason)
}

public struct Translator: Sendable {
    public init() {}

    public func translate(metadata: ModelRequestMetadata, body: Data, endpoint: CheapRouterEndpoint) -> TranslationResult<CheapRouterRequestPayload> {
        guard metadata.action == .generateContent || metadata.action == .streamGenerateContent else {
            return .failClosed(reason: .unsupportedAction)
        }
        guard let rootObject = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .failClosed(reason: .unsupportedSchema)
        }
        let object = requestObject(from: rootObject)

        let translated: [String: Any]?
        switch endpoint {
        case .chatCompletions:
            translated = makeOpenAIChatPayload(metadata: metadata, object: object)
        case .messages:
            translated = makeAnthropicMessagesPayload(metadata: metadata, object: object)
        case .models, .responses:
            translated = nil
        }

        guard let translated,
              JSONSerialization.isValidJSONObject(translated),
              let data = try? JSONSerialization.data(withJSONObject: translated, options: [.sortedKeys])
        else {
            return .failClosed(reason: .unsupportedSchema)
        }

        return .success(CheapRouterRequestPayload(endpoint: endpoint, model: metadata.model, body: data))
    }

    private func requestObject(from object: [String: Any]) -> [String: Any] {
        if let request = object["request"] as? [String: Any] {
            return request
        }
        return object
    }

    private func makeOpenAIChatPayload(metadata: ModelRequestMetadata, object: [String: Any]) -> [String: Any]? {
        guard let messages = googleGenerateContentMessages(from: object, includeSystemMessage: true), !messages.isEmpty else {
            return nil
        }

        var payload: [String: Any] = [
            "model": metadata.model,
            "messages": messages,
            "stream": metadata.action == .streamGenerateContent
        ]
        applyGenerationConfig(from: object, to: &payload)
        return payload
    }

    private func makeAnthropicMessagesPayload(metadata: ModelRequestMetadata, object: [String: Any]) -> [String: Any]? {
        guard let messages = googleGenerateContentMessages(from: object, includeSystemMessage: false), !messages.isEmpty else {
            return nil
        }

        var payload: [String: Any] = [
            "model": metadata.model,
            "messages": messages,
            "stream": metadata.action == .streamGenerateContent
        ]
        if let system = systemInstructionText(from: object) {
            payload["system"] = system
        }
        applyGenerationConfig(from: object, to: &payload)
        payload["max_tokens"] = payload["max_tokens"] ?? 4096
        return payload
    }

    private func applyGenerationConfig(from object: [String: Any], to payload: inout [String: Any]) {
        guard let config = object["generationConfig"] as? [String: Any] else { return }
        if let temperature = config["temperature"] {
            payload["temperature"] = temperature
        }
        if let maxOutputTokens = config["maxOutputTokens"] {
            payload["max_tokens"] = maxOutputTokens
        }
    }

    private func googleGenerateContentMessages(from object: [String: Any], includeSystemMessage: Bool) -> [[String: String]]? {
        var messages: [[String: String]] = []
        if includeSystemMessage, let system = systemInstructionText(from: object) {
            messages.append(["role": "system", "content": system])
        }

        guard let contents = object["contents"] as? [[String: Any]] else {
            return nil
        }
        for content in contents {
            guard let text = textFromParts(content["parts"]), !text.isEmpty else {
                return nil
            }
            let googleRole = content["role"] as? String ?? "user"
            messages.append(["role": openAIRole(fromGoogleRole: googleRole), "content": text])
        }
        return messages
    }

    private func systemInstructionText(from object: [String: Any]) -> String? {
        guard let systemInstruction = object["systemInstruction"] as? [String: Any] else {
            return nil
        }
        return textFromParts(systemInstruction["parts"])
    }

    private func textFromParts(_ value: Any?) -> String? {
        guard let parts = value as? [[String: Any]] else {
            return nil
        }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private func openAIRole(fromGoogleRole role: String) -> String {
        role == "model" ? "assistant" : role
    }
}

public struct CheapRouterRequestPayload: Equatable, Sendable {
    public var endpoint: CheapRouterEndpoint
    public var model: String
    public var body: Data

    public init(endpoint: CheapRouterEndpoint, model: String, body: Data) {
        self.endpoint = endpoint
        self.model = model
        self.body = body
    }
}

public struct ProxyHTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func normalizedForClient() -> ProxyHTTPResponse {
        var normalized: [String: String] = [:]
        for (name, value) in headers {
            let lower = name.lowercased()
            guard lower != "content-length",
                  lower != "transfer-encoding",
                  lower != "connection",
                  lower != "content-encoding",
                  lower != "content-md5"
            else { continue }
            normalized[name] = value
        }
        normalized["Content-Length"] = "\(body.count)"
        normalized["Connection"] = "close"
        return ProxyHTTPResponse(statusCode: statusCode, headers: normalized, body: body)
    }
}

public struct ResponseTranslator: Sendable {
    public init() {}

    public func translate(response: CheapRouterResponse, metadata: ModelRequestMetadata) -> ProxyHTTPResponse {
        guard (200..<300).contains(response.statusCode) else {
            return ProxyHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: response.body)
        }

        switch metadata.action {
        case .streamGenerateContent:
            return ProxyHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/event-stream", "cache-control": "no-cache"],
                body: translateSSE(response.body, model: metadata.model)
            )
        case .generateContent:
            return ProxyHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: translateJSON(response.body, model: metadata.model)
            )
        default:
            return ProxyHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: response.body)
        }
    }

    private func translateSSE(_ body: Data, model: String) -> Data {
        let text = String(decoding: body, as: UTF8.self)
        var output = Data()
        let responseID = "resp_\(UUID().uuidString)"

        for event in text.components(separatedBy: "\n\n") {
            for line in event.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !payload.isEmpty, payload != "[DONE]" else { continue }
                guard let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                for chunk in googleGenerateContentChunks(fromSSEObject: object, fallbackModel: model, responseID: responseID) {
                    output.append(Data("data: \(chunk)\r\n\r\n".utf8))
                }
            }
        }

        output.append(Data("data: [DONE]\r\n\r\n".utf8))
        return output
    }

    private func translateJSON(_ body: Data, model: String) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return body
        }
        if object["candidates"] != nil {
            return body
        }

        let text: String
        let finishReason: String
        let usage: [String: Any]?
        let responseModel: String

        if let choice = (object["choices"] as? [[String: Any]])?.first {
            let message = choice["message"] as? [String: Any]
            text = message?["content"] as? String ?? ""
            finishReason = mapFinishReason(choice["finish_reason"] as? String)
            usage = object["usage"] as? [String: Any]
            responseModel = object["model"] as? String ?? model
        } else if let content = object["content"] as? [[String: Any]] {
            text = content.compactMap { $0["text"] as? String }.joined()
            finishReason = mapFinishReason(object["stop_reason"] as? String)
            usage = anthropicUsageObject(object["usage"] as? [String: Any])
            responseModel = object["model"] as? String ?? model
        } else {
            return body
        }

        let googleResponse = googleGenerateContentResponseObject(text: text, finishReason: finishReason, usage: usage, model: responseModel)
        return (try? JSONSerialization.data(withJSONObject: googleResponse, options: [.sortedKeys])) ?? body
    }

    private func googleGenerateContentChunks(fromSSEObject object: [String: Any], fallbackModel: String, responseID: String) -> [String] {
        if let choice = (object["choices"] as? [[String: Any]])?.first {
            let delta = choice["delta"] as? [String: Any] ?? [:]
            var chunks: [String] = []
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                chunks.append(googleGenerateContentSSEChunk(text: reasoning, thought: true, responseID: responseID))
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                chunks.append(googleGenerateContentSSEChunk(text: content, responseID: responseID))
            }
            if let finishReason = choice["finish_reason"] as? String {
                chunks.append(googleGenerateContentSSEChunk(
                    text: "",
                    finishReason: mapFinishReason(finishReason),
                    usage: object["usage"] as? [String: Any],
                    model: object["model"] as? String ?? fallbackModel,
                    responseID: responseID
                ))
            }
            return chunks
        }

        guard let type = object["type"] as? String else { return [] }
        if type == "content_block_delta",
           let delta = object["delta"] as? [String: Any],
           let text = delta["text"] as? String,
           !text.isEmpty {
            return [googleGenerateContentSSEChunk(text: text, responseID: responseID)]
        }
        if type == "message_delta" {
            let delta = object["delta"] as? [String: Any] ?? [:]
            return [googleGenerateContentSSEChunk(
                text: "",
                finishReason: mapFinishReason(delta["stop_reason"] as? String),
                usage: anthropicUsageObject(object["usage"] as? [String: Any]),
                model: fallbackModel,
                responseID: responseID
            )]
        }
        return []
    }

    private func googleGenerateContentSSEChunk(
        text: String,
        thought: Bool = false,
        finishReason: String? = nil,
        usage: [String: Any]? = nil,
        model: String? = nil,
        responseID: String
    ) -> String {
        var part: [String: Any] = ["text": text]
        if thought {
            part["thought"] = true
        }
        var candidate: [String: Any] = [
            "content": ["role": "model", "parts": [part]],
            "index": 0
        ]
        if let finishReason {
            candidate["finishReason"] = finishReason
        }
        var object: [String: Any] = ["candidates": [candidate]]
        if let usage {
            object["usageMetadata"] = googleGenerateContentUsageObject(usage)
        }
        if let model {
            object["modelVersion"] = model
        }
        object["responseId"] = responseID
        object = ["response": object]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? #"{"response":{"candidates":[]}}"#
    }

    private func googleGenerateContentResponseObject(text: String, finishReason: String, usage: [String: Any]?, model: String) -> [String: Any] {
        var object: [String: Any] = [
            "candidates": [[
                "content": ["role": "model", "parts": [["text": text]]],
                "finishReason": finishReason,
                "index": 0
            ]],
            "modelVersion": model
        ]
        if let usage {
            object["usageMetadata"] = googleGenerateContentUsageObject(usage)
        }
        return object
    }

    private func googleGenerateContentUsageObject(_ usage: [String: Any]) -> [String: Any] {
        [
            "promptTokenCount": intValue(usage["prompt_tokens"] ?? usage["input_tokens"]),
            "candidatesTokenCount": intValue(usage["completion_tokens"] ?? usage["output_tokens"]),
            "totalTokenCount": intValue(usage["total_tokens"])
        ].filter { _, value in value > 0 }
    }

    private func anthropicUsageObject(_ usage: [String: Any]?) -> [String: Any]? {
        guard let usage else { return nil }
        let input = intValue(usage["input_tokens"])
        let output = intValue(usage["output_tokens"])
        return [
            "input_tokens": input,
            "output_tokens": output,
            "total_tokens": input + output
        ]
    }

    private func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private func mapFinishReason(_ reason: String?) -> String {
        switch reason {
        case "length", "max_tokens": "MAX_TOKENS"
        case "content_filter": "SAFETY"
        default: "STOP"
        }
    }
}
