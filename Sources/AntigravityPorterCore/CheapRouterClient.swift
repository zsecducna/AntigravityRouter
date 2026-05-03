import Foundation

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

    public init(configuration: CheapRouterClientConfiguration) {
        self.configuration = configuration
    }

    public func request(endpoint: CheapRouterEndpoint, body: Data) -> CheapRouterRequest {
        CheapRouterRequest(
            endpoint: endpoint,
            url: configuration.baseURL.appendingPathComponent(endpoint.path),
            headers: [
                "Authorization": "Bearer \(configuration.apiKey)",
                "Content-Type": "application/json"
            ],
            body: body
        )
    }
}
