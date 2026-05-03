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
    public var configuration: CheapRouterClientConfiguration
    private let transport: any CheapRouterTransport

    public init(configuration: CheapRouterClientConfiguration, transport: any CheapRouterTransport = URLSessionCheapRouterTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public func request(endpoint: CheapRouterEndpoint, body: Data) -> CheapRouterRequest {
        CheapRouterRequest(
            endpoint: endpoint,
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
        request.httpBody = cheapRouterRequest.body
        for (name, value) in cheapRouterRequest.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    public func send(endpoint: CheapRouterEndpoint, body: Data) async throws -> CheapRouterResponse {
        try await transport.send(urlRequest(endpoint: endpoint, body: body))
    }

    private func endpointURL(_ endpoint: CheapRouterEndpoint) -> URL {
        configuration.baseURL.appendingPathComponent(endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
