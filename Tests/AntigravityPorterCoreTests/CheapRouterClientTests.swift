import XCTest
@testable import AntigravityPorterCore

final class CheapRouterClientTests: XCTestCase {
    func testBuildsAuthenticatedRequestWithoutDoubleSlashEndpoint() throws {
        let client = CheapRouterClient(configuration: .init(baseURL: URL(string: "https://cheaprouter.uk/")!, apiKey: "cr_secret"))
        let body = Data(#"{"model":"gpt-5.5"}"#.utf8)

        let request = client.urlRequest(endpoint: .chatCompletions, body: body)

        XCTAssertEqual(request.url?.absoluteString, "https://cheaprouter.uk/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cr_secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody, body)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testSendUsesInjectedTransport() async throws {
        let transport = RecordingCheapRouterTransport(response: .init(statusCode: 200, headers: ["content-type": "application/json"], body: Data(#"{"ok":true}"#.utf8)))
        let client = CheapRouterClient(configuration: .init(baseURL: URL(string: "https://cheaprouter.uk")!, apiKey: "cr_secret"), transport: transport)

        let response = try await client.send(endpoint: .messages, body: Data(#"{"model":"claude-sonnet-4"}"#.utf8))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(transport.requests.map { $0.url?.path }, ["/v1/messages"])
    }

    func testModelsRequestUsesGETWithoutBody() {
        let client = CheapRouterClient(configuration: .init(baseURL: URL(string: "https://cheaprouter.uk")!, apiKey: "cr_secret"))

        let request = client.urlRequest(endpoint: .models, body: Data(#"{"ignored":true}"#.utf8))

        XCTAssertEqual(request.url?.absoluteString, "https://cheaprouter.uk/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cr_secret")
    }

    func testFetchModelsParsesOpenAIAndClaudeModelLists() async throws {
        let body = Data("""
        {
          "object": "list",
          "data": [
            {"id": "gpt-5.5", "object": "model"},
            {"id": "claude-sonnet-4-6", "type": "model"},
            {"id": "anthropic/claude-opus-4-6", "owned_by": "anthropic"}
          ],
          "anthropic": [
            {"id": "claude-opus-4-6-thinking"}
          ],
          "openai": ["gpt-oss-120b-medium"],
          "notes": ["not-a-model-id"]
        }
        """.utf8)
        let transport = RecordingCheapRouterTransport(response: .init(statusCode: 200, headers: ["content-type": "application/json"], body: body))
        let client = CheapRouterClient(configuration: .init(baseURL: URL(string: "https://cheaprouter.uk")!, apiKey: "cr_secret"), transport: transport)

        let models = try await client.fetchModels().map(\.id)

        XCTAssertEqual(models, ["anthropic/claude-opus-4-6", "claude-opus-4-6-thinking", "claude-sonnet-4-6", "gpt-5.5", "gpt-oss-120b-medium"])
        XCTAssertEqual(transport.requests.map { $0.url?.path }, ["/v1/models"])
    }

    func testURLSessionTransportDisablesSystemProxyLookup() {
        let configuration = URLSessionCheapRouterTransport.proxyBypassingConfiguration()

        XCTAssertEqual(configuration.connectionProxyDictionary?["HTTPEnable"] as? Bool, false)
        XCTAssertEqual(configuration.connectionProxyDictionary?["HTTPSEnable"] as? Bool, false)
    }
}

final class RecordingCheapRouterTransport: CheapRouterTransport, @unchecked Sendable {
    private let response: CheapRouterResponse
    private(set) var requests: [URLRequest] = []

    init(response: CheapRouterResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> CheapRouterResponse {
        requests.append(request)
        return response
    }
}
