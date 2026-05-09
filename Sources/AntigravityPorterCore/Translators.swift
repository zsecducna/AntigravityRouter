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
    public var providerModelAliases: [String: String]

    public init(
        customProviderRoutingEnabled: Bool = false,
        supportedActions: Set<PorterAction> = [.generateContent, .streamGenerateContent],
        providerModelAliases: [String: String] = [:]
    ) {
        self.customProviderRoutingEnabled = customProviderRoutingEnabled
        self.supportedActions = supportedActions
        self.providerModelAliases = providerModelAliases
    }
}

public struct RoutingEngine: Sendable {
    public var config: RoutingEngineConfiguration

    public init(config: RoutingEngineConfiguration) {
        self.config = config
    }

    public func decision(for metadata: ModelRequestMetadata) -> RoutingDecision {
        guard config.customProviderRoutingEnabled else { return .googleDirect }
        guard config.providerModelAliases[metadata.model] != nil else {
            return metadata.model.hasPrefix("MODEL_PLACEHOLDER_M")
                ? .failClosed(reason: .unsupportedModel)
                : .googleDirect
        }
        guard config.supportedActions.contains(metadata.action) else { return .failClosed(reason: .unsupportedAction) }
        return .cheapRouter(endpoint: .responses)
    }

    public func resolvedMetadata(for metadata: ModelRequestMetadata) -> ModelRequestMetadata {
        guard let providerModel = config.providerModelAliases[metadata.model],
              providerModel != metadata.model
        else { return metadata }
        return ModelRequestMetadata(client: metadata.client, model: providerModel, action: metadata.action)
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
        case .responses:
            translated = makeOpenAIResponsesPayload(metadata: metadata, object: object)
        case .models:
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

    private func makeOpenAIResponsesPayload(metadata: ModelRequestMetadata, object: [String: Any]) -> [String: Any]? {
        guard let input = googleGenerateContentResponsesInput(from: object), !input.isEmpty else {
            return nil
        }

        var payload: [String: Any] = [
            "model": metadata.model,
            "input": input,
            "stream": metadata.action == .streamGenerateContent
        ]
        if let system = systemInstructionText(from: object) {
            payload["instructions"] = system
        }
        if let tools = openAIResponsesTools(from: object["tools"]) {
            payload["tools"] = tools
        }
        applyResponsesGenerationConfig(from: object, to: &payload)
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

    private func applyResponsesGenerationConfig(from object: [String: Any], to payload: inout [String: Any]) {
        guard let config = object["generationConfig"] as? [String: Any] else { return }
        if let temperature = config["temperature"] {
            payload["temperature"] = temperature
        }
        if let maxOutputTokens = config["maxOutputTokens"] {
            payload["max_output_tokens"] = maxOutputTokens
        }
    }

    private func openAIResponsesTools(from value: Any?) -> [[String: Any]]? {
        guard let googleTools = value as? [[String: Any]] else { return nil }
        var tools: [[String: Any]] = []
        for googleTool in googleTools {
            guard let declarations = googleTool["functionDeclarations"] as? [[String: Any]] else { continue }
            for declaration in declarations {
                guard let name = declaration["name"] as? String, !name.isEmpty else { continue }
                var tool: [String: Any] = [
                    "type": "function",
                    "name": name
                ]
                if let description = declaration["description"] as? String {
                    tool["description"] = description
                }
                if let parameters = declaration["parameters"] {
                    tool["parameters"] = normalizeJSONSchemaTypes(parameters)
                }
                tools.append(tool)
            }
        }
        return tools.isEmpty ? nil : tools
    }

    private func googleGenerateContentResponsesInput(from object: [String: Any]) -> [[String: Any]]? {
        guard let contents = object["contents"] as? [[String: Any]] else {
            return nil
        }
        var input: [[String: Any]] = []
        for content in contents {
            let googleRole = content["role"] as? String ?? "user"
            let role = openAIRole(fromGoogleRole: googleRole)
            guard let parts = content["parts"] as? [[String: Any]] else {
                return nil
            }
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty {
                input.append(["role": role, "content": text])
            }
            for part in parts {
                if let functionCall = part["functionCall"] as? [String: Any],
                   let item = responsesFunctionCallInputItem(from: functionCall) {
                    input.append(item)
                }
                if let functionResponse = part["functionResponse"] as? [String: Any],
                   let item = responsesFunctionCallOutputItem(from: functionResponse) {
                    input.append(item)
                }
            }
        }
        return input
    }

    private func responsesFunctionCallInputItem(from functionCall: [String: Any]) -> [String: Any]? {
        guard let name = functionCall["name"] as? String, !name.isEmpty else { return nil }
        let callID = functionCall["id"] as? String ?? functionCall["call_id"] as? String ?? name
        return [
            "type": "function_call",
            "call_id": callID,
            "name": name,
            "arguments": jsonString(functionCall["args"] ?? [:])
        ]
    }

    private func responsesFunctionCallOutputItem(from functionResponse: [String: Any]) -> [String: Any]? {
        guard let name = functionResponse["name"] as? String, !name.isEmpty else { return nil }
        let callID = functionResponse["id"] as? String ?? functionResponse["call_id"] as? String ?? name
        return [
            "type": "function_call_output",
            "call_id": callID,
            "output": jsonString(functionResponse["response"] ?? [:])
        ]
    }

    private func normalizeJSONSchemaTypes(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            if let type = object["type"] as? String {
                object["type"] = type.lowercased()
            }
            for (key, child) in object {
                object[key] = normalizeJSONSchemaTypes(child)
            }
            return object
        }
        if let array = value as? [Any] {
            return array.map(normalizeJSONSchemaTypes)
        }
        return value
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

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
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
            let translated = translateSSE(response.body, model: metadata.model)
            guard !translated.isEmpty else {
                return providerStreamFailureResponse()
            }
            return ProxyHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/event-stream", "cache-control": "no-cache"],
                body: translated
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
        var translatedChunkCount = 0

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
                    translatedChunkCount += 1
                }
            }
        }

        guard translatedChunkCount > 0 else {
            return Data()
        }
        output.append(Data("data: [DONE]\r\n\r\n".utf8))
        return output
    }

    private func providerStreamFailureResponse() -> ProxyHTTPResponse {
        let body = Data(#"{"error":{"message":"provider stream response was empty or unsupported"}}"#.utf8)
        return ProxyHTTPResponse(
            statusCode: 502,
            headers: ["content-type": "application/json", "content-length": "\(body.count)"],
            body: body
        )
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
        } else if object["object"] as? String == "response" || object["output_text"] != nil || object["output"] != nil {
            if let functionCall = googleFunctionCallResponseObject(fromResponsesObject: object, model: model) {
                return (try? JSONSerialization.data(withJSONObject: functionCall, options: [.sortedKeys])) ?? body
            }
            text = responsesText(from: object)
            finishReason = mapFinishReason(nil)
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
        if type == "response.output_text.delta",
           let delta = object["delta"] as? String,
           !delta.isEmpty {
            return [googleGenerateContentSSEChunk(text: delta, responseID: responseID)]
        }
        if (type == "response.reasoning_text.delta" || type == "response.reasoning_summary_text.delta"),
           let delta = object["delta"] as? String,
           !delta.isEmpty {
            return [googleGenerateContentSSEChunk(text: delta, thought: true, responseID: responseID)]
        }
        if type == "response.output_item.done",
           let item = object["item"] as? [String: Any],
           let functionCall = googleFunctionCallPart(fromResponsesItem: item) {
            return [googleGenerateContentSSEChunk(part: functionCall, responseID: responseID)]
        }
        if type == "response.completed" {
            let response = object["response"] as? [String: Any] ?? [:]
            return [googleGenerateContentSSEChunk(
                text: "",
                finishReason: mapFinishReason(nil),
                usage: response["usage"] as? [String: Any],
                model: response["model"] as? String ?? fallbackModel,
                responseID: responseID
            )]
        }
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

    private func responsesText(from object: [String: Any]) -> String {
        if let outputText = object["output_text"] as? String {
            return outputText
        }
        guard let output = object["output"] as? [[String: Any]] else { return "" }
        return output.compactMap { item -> String? in
            guard let content = item["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                if let text = part["content"] as? String { return text }
                return nil
            }.joined()
        }.joined()
    }

    private func googleFunctionCallResponseObject(fromResponsesObject object: [String: Any], model: String) -> [String: Any]? {
        guard let output = object["output"] as? [[String: Any]] else { return nil }
        let functionCalls = output.compactMap(googleFunctionCallPart(fromResponsesItem:))
        guard !functionCalls.isEmpty else { return nil }
        return [
            "candidates": [[
                "content": ["role": "model", "parts": functionCalls],
                "finishReason": "STOP",
                "index": 0
            ]],
            "modelVersion": object["model"] as? String ?? model
        ]
    }

    private func googleFunctionCallPart(fromResponsesItem item: [String: Any]) -> [String: Any]? {
        guard item["type"] as? String == "function_call",
              let name = item["name"] as? String,
              !name.isEmpty
        else { return nil }
        var functionCall: [String: Any] = [
            "name": name,
            "args": jsonObject(fromString: item["arguments"] as? String) ?? [:]
        ]
        if let callID = item["call_id"] as? String ?? item["id"] as? String {
            functionCall["id"] = callID
        }
        return ["functionCall": functionCall]
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

    private func googleGenerateContentSSEChunk(part: [String: Any], responseID: String) -> String {
        let object: [String: Any] = [
            "response": [
                "candidates": [[
                    "content": ["role": "model", "parts": [part]],
                    "index": 0
                ]],
                "responseId": responseID
            ]
        ]
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

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonObject(fromString value: String?) -> [String: Any]? {
        guard let value,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}

public enum AntigravityModelCatalogInjector {
    public struct InjectionReport: Equatable, Sendable {
        public let body: Data
        public let providerModelCount: Int
        public let insertedModelCount: Int
        public let modelAliases: [String: String]
    }

    public static func injectProviderModels(_ providerModels: [ProviderModel], into body: Data) -> Data {
        injectProviderModelsWithReport(providerModels, into: body).body
    }

    public static func injectProviderModelsWithReport(_ providerModels: [ProviderModel], into body: Data) -> InjectionReport {
        guard !providerModels.isEmpty,
              var root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              var models = root["models"] as? [String: Any]
        else {
            return InjectionReport(body: body, providerModelCount: providerModels.count, insertedModelCount: 0, modelAliases: [:])
        }

        var usedModelValues = Set(models.compactMap { _, value -> String? in
            (value as? [String: Any])?["model"] as? String
        })
        var insertedIDs: [String] = []
        var modelAliases: [String: String] = [:]
        for providerModel in providerModels {
            guard let id = CheapRouterClient.normalizedProviderModelID(providerModel.id),
                  models[id] == nil
            else { continue }
            let modelValue = placeholderModelValue(for: id, usedModelValues: &usedModelValues)
            models[id] = injectedModelObject(id: id, modelValue: modelValue)
            insertedIDs.append(id)
            modelAliases[id] = id
            modelAliases[modelValue] = id
        }
        guard !insertedIDs.isEmpty else {
            return InjectionReport(body: body, providerModelCount: providerModels.count, insertedModelCount: 0, modelAliases: [:])
        }

        root["models"] = models
        root["agentModelSorts"] = injectAgentModelSorts(root["agentModelSorts"], insertedIDs: insertedIDs)
        let injectedBody = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? body
        return InjectionReport(body: injectedBody, providerModelCount: providerModels.count, insertedModelCount: insertedIDs.count, modelAliases: modelAliases)
    }

    private static func injectedModelObject(id: String, modelValue: String) -> [String: Any] {
        [
            "displayName": id,
            "maxTokens": 1_048_576,
            "maxOutputTokens": 65_535,
            "tokenizerType": "LLAMA_WITH_SPECIAL",
            "quotaInfo": ["remainingFraction": 1],
            "model": modelValue,
            "apiProvider": "API_PROVIDER_GOOGLE_GEMINI",
            "modelProvider": "MODEL_PROVIDER_GOOGLE",
            "recommended": true,
            "supportsImages": false,
            "supportsThinking": false,
            "supportedMimeTypes": [:],
            "modelExperiments": ["experiments": [:]]
        ]
    }

    private static func placeholderModelValue(for id: String, usedModelValues: inout Set<String>) -> String {
        let candidates = (100...150).map { "MODEL_PLACEHOLDER_M\($0)" }
            + (90...99).map { "MODEL_PLACEHOLDER_M\($0)" }
            + (0...89).map { "MODEL_PLACEHOLDER_M\($0)" }
        let startIndex = Int(stableHash(id) % UInt64(candidates.count))
        for offset in candidates.indices {
            let candidate = candidates[(startIndex + offset) % candidates.count]
            if !usedModelValues.contains(candidate) {
                usedModelValues.insert(candidate)
                return candidate
            }
        }
        var suffix = Int(stableHash(id) % 1_000_000) + 151
        while true {
            let candidate = "MODEL_PLACEHOLDER_M\(suffix)"
            if !usedModelValues.contains(candidate) {
                usedModelValues.insert(candidate)
                return candidate
            }
            suffix += 1
        }
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func injectAgentModelSorts(_ value: Any?, insertedIDs: [String]) -> [[String: Any]] {
        let injectedGroup: [String: Any] = [
            "displayName": "Target provider",
            "modelIds": insertedIDs
        ]
        var sorts = value as? [[String: Any]] ?? []
        if sorts.isEmpty {
            return [["displayName": "Target provider", "groups": [injectedGroup]]]
        }

        var first = sorts[0]
        var groups = first["groups"] as? [[String: Any]] ?? []
        if groups.isEmpty {
            groups = [injectedGroup]
        } else {
            var primary = groups[0]
            let existingIDs = primary["modelIds"] as? [String] ?? []
            primary["modelIds"] = existingIDs + insertedIDs.filter { !existingIDs.contains($0) }
            groups[0] = primary
            groups.append(injectedGroup)
        }
        first["groups"] = groups
        sorts[0] = first
        return sorts
    }
}
