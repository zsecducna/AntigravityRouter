import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif

public struct CheapRouterRequest: Equatable, Sendable {
    public var endpoint: CheapRouterEndpoint
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data

    public init(endpoint: CheapRouterEndpoint, method: String = "POST", url: URL, headers: [String: String], body: Data) {
        self.endpoint = endpoint
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct CheapRouterResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum CheapRouterClientError: Error, Equatable, Sendable {
    case nonHTTPResponse
    case badStatus(Int)
    case invalidModelsResponse
}

public struct ProviderModel: Equatable, Identifiable, Sendable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

public protocol CheapRouterTransport: Sendable {
    func send(_ request: URLRequest) async throws -> CheapRouterResponse
}

public struct URLSessionCheapRouterTransport: CheapRouterTransport, @unchecked Sendable {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = Self.proxyBypassingConfiguration()) {
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> CheapRouterResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CheapRouterClientError.nonHTTPResponse
        }
        let headers: [String: String] = Dictionary(uniqueKeysWithValues: httpResponse.allHeaderFields.compactMap { key, value in
            guard let key = key as? String else { return nil }
            return (key, String(describing: value))
        })
        return CheapRouterResponse(statusCode: httpResponse.statusCode, headers: headers, body: data)
    }

    public static func proxyBypassingConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        #if canImport(CFNetwork)
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false
        ]
        #else
        configuration.connectionProxyDictionary = [:]
        #endif
        return configuration
    }
}

public struct CheapRouterClientConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var apiKey: String

    public init(baseURL: URL = URL(string: "https://cheaprouter.uk")!, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

public struct CheapRouterClient: Sendable {
    private static let maximumProviderModels = 200
    private static let maximumProviderModelIDLength = 128
    private static let providerModelIDCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/@+-")

    public var configuration: CheapRouterClientConfiguration
    private let transport: any CheapRouterTransport

    public init(configuration: CheapRouterClientConfiguration, transport: any CheapRouterTransport = URLSessionCheapRouterTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public func request(endpoint: CheapRouterEndpoint, body: Data) -> CheapRouterRequest {
        CheapRouterRequest(
            endpoint: endpoint,
            method: endpoint == .models ? "GET" : "POST",
            url: endpointURL(endpoint),
            headers: [
                "Authorization": "Bearer \(configuration.apiKey)",
                "Content-Type": "application/json"
            ],
            body: body
        )
    }

    public func urlRequest(endpoint: CheapRouterEndpoint, body: Data) -> URLRequest {
        let cheapRouterRequest = request(endpoint: endpoint, body: body)
        var request = URLRequest(url: cheapRouterRequest.url)
        request.httpMethod = cheapRouterRequest.method
        if cheapRouterRequest.method != "GET" {
            request.httpBody = cheapRouterRequest.body
        }
        for (name, value) in cheapRouterRequest.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    public func send(endpoint: CheapRouterEndpoint, body: Data) async throws -> CheapRouterResponse {
        try await transport.send(urlRequest(endpoint: endpoint, body: body))
    }

    public func fetchModels() async throws -> [ProviderModel] {
        let response = try await send(endpoint: .models, body: Data())
        guard (200..<300).contains(response.statusCode) else {
            throw CheapRouterClientError.badStatus(response.statusCode)
        }
        let models = try Self.parseModelsResponse(response.body)
        guard !models.isEmpty else {
            throw CheapRouterClientError.invalidModelsResponse
        }
        return models
    }

    public static func parseModelsResponse(_ body: Data) throws -> [ProviderModel] {
        guard let root = try? JSONSerialization.jsonObject(with: body) else {
            throw CheapRouterClientError.invalidModelsResponse
        }
        var ids: [String] = []
        collectModelIDs(from: root, into: &ids, acceptBareStrings: false)
        var seen = Set<String>()
        var models: [ProviderModel] = []
        for id in ids {
            guard let normalized = normalizedProviderModelID(id),
                  seen.insert(normalized).inserted
            else { continue }
            models.append(ProviderModel(id: normalized))
            if models.count >= maximumProviderModels { break }
        }
        return models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    public static func normalizedProviderModelID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= maximumProviderModelIDLength else { return nil }
        guard id.unicodeScalars.allSatisfy({ providerModelIDCharacters.contains($0) }) else { return nil }
        return id
    }

    private static func collectModelIDs(from value: Any, into ids: inout [String], acceptBareStrings: Bool) {
        if let string = value as? String {
            if acceptBareStrings {
                ids.append(string)
            }
            return
        }
        if let array = value as? [Any] {
            for item in array {
                collectModelIDs(from: item, into: &ids, acceptBareStrings: acceptBareStrings)
            }
            return
        }
        guard let object = value as? [String: Any] else { return }
        if let id = object["id"] as? String {
            ids.append(id)
        } else if let id = object["model"] as? String, object["id"] == nil {
            ids.append(id)
        }
        for key in ["data", "models"] {
            if let nested = object[key] {
                collectModelIDs(from: nested, into: &ids, acceptBareStrings: false)
            }
        }
        for key in ["openai", "anthropic", "claude"] {
            if let nested = object[key] {
                collectModelIDs(from: nested, into: &ids, acceptBareStrings: true)
            }
        }
    }

    private func endpointURL(_ endpoint: CheapRouterEndpoint) -> URL {
        configuration.baseURL.appendingPathComponent(endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
