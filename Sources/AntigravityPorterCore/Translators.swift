import Foundation

public enum PorterClient: Equatable, Sendable {
    case geminiCLI
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
        let client: PorterClient = host == "generativelanguage.googleapis.com" ? .geminiCLI : .antigravity
        let action = actionFromPath(path)
        if client == .geminiCLI, let model = geminiModelFromPath(path) {
            return ModelRequestMetadata(client: client, model: model, action: action)
        }
        if let model = modelFromJSON(body) {
            return ModelRequestMetadata(client: client, model: model, action: action)
        }
        throw ModelExtractorError.modelNotFound
    }

    private static func actionFromPath(_ path: String) -> PorterAction {
        if path.contains(":streamGenerateContent") { return .streamGenerateContent }
        if path.contains(":generateContent") { return .generateContent }
        if path.contains(":countTokens") { return .countTokens }
        return .unknown(path)
    }

    private static func geminiModelFromPath(_ path: String) -> String? {
        guard let range = path.range(of: "/models/") else { return nil }
        let suffix = path[range.upperBound...]
        let end = suffix.firstIndex { $0 == ":" || $0 == "?" } ?? suffix.endIndex
        let model = String(suffix[..<end])
        return model.isEmpty ? nil : model
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
    case responses

    public var path: String {
        switch self {
        case .chatCompletions: "/v1/chat/completions"
        case .messages: "/v1/messages"
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
    public var routedModels: Set<String>
    public var supportedActions: Set<PorterAction>

    public init(routedModels: Set<String>, supportedActions: Set<PorterAction> = [.generateContent, .streamGenerateContent]) {
        self.routedModels = routedModels
        self.supportedActions = supportedActions
    }

    public init(routedModels: [String], supportedActions: Set<PorterAction> = [.generateContent, .streamGenerateContent]) {
        self.init(routedModels: Set(routedModels), supportedActions: supportedActions)
    }
}

public struct RoutingEngine: Sendable {
    public var config: RoutingEngineConfiguration

    public init(config: RoutingEngineConfiguration) {
        self.config = config
    }

    public func decision(for metadata: ModelRequestMetadata) -> RoutingDecision {
        guard config.routedModels.contains(metadata.model) else { return .googleDirect }
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
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .failClosed(reason: .unsupportedSchema)
        }

        let translated: [String: Any]?
        switch endpoint {
        case .chatCompletions:
            translated = makeOpenAIChatPayload(metadata: metadata, object: object)
        case .messages:
            translated = makeAnthropicMessagesPayload(metadata: metadata, object: object)
        case .responses:
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

    private func makeOpenAIChatPayload(metadata: ModelRequestMetadata, object: [String: Any]) -> [String: Any]? {
        guard let messages = geminiMessages(from: object, includeSystemMessage: true), !messages.isEmpty else {
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
        guard let messages = geminiMessages(from: object, includeSystemMessage: false), !messages.isEmpty else {
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
        guard payload["max_tokens"] != nil else {
            return nil
        }
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

    private func geminiMessages(from object: [String: Any], includeSystemMessage: Bool) -> [[String: String]]? {
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
            let geminiRole = content["role"] as? String ?? "user"
            messages.append(["role": openAIRole(fromGeminiRole: geminiRole), "content": text])
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

    private func openAIRole(fromGeminiRole role: String) -> String {
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
