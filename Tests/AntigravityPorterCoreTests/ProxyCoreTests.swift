import XCTest
@testable import AntigravityPorterCore

final class ProxyCoreTests: XCTestCase {
    func testParsesConnectAuthorityAndHeaders() throws {
        let request = """
        CONNECT cloudcode-pa.googleapis.com:443 HTTP/1.1\r
        Host: cloudcode-pa.googleapis.com:443\r
        User-Agent: Antigravity\r
        \r
        """

        let connect = try ConnectRequestParser.parse(Data(request.utf8))

        XCTAssertEqual(connect.host, "cloudcode-pa.googleapis.com")
        XCTAssertEqual(connect.port, 443)
        XCTAssertEqual(connect.httpVersion, "HTTP/1.1")
        XCTAssertEqual(connect.headers["host"], "cloudcode-pa.googleapis.com:443")
    }

    func testRejectsNonConnectAndMalformedAuthority() {
        XCTAssertThrowsError(try ConnectRequestParser.parse(Data("GET / HTTP/1.1\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? ConnectParseError, .unsupportedMethod("GET"))
        }
        XCTAssertThrowsError(try ConnectRequestParser.parse(Data("CONNECT missing-port HTTP/1.1\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? ConnectParseError, .invalidAuthority("missing-port"))
        }
    }

    func testProtocolGateRequiresSupportedALPNBeforeInterception() {
        XCTAssertEqual(ProxyProtocolGate.decision(for: .http1_1, hostDecision: .intercept), .terminateTLS)
        XCTAssertEqual(ProxyProtocolGate.decision(for: .h2, hostDecision: .intercept), .failClosed(reason: .unsupportedALPN(.h2)))
        XCTAssertEqual(ProxyProtocolGate.decision(for: .http1_1, hostDecision: .blindTunnel), .blindTunnel)
    }

    func testParsesHTTP11RequestAndKeepsOnlyDeclaredBodyBytes() throws {
        let body = #"{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}"#
        let request = """
        POST /v1beta/models/gemini-2.5-pro:generateContent HTTP/1.1\r
        Host: generativelanguage.googleapis.com\r
        Content-Length: \(body.utf8.count)\r
        Proxy-Authorization: Basic secret\r
        \r
        \(body)ignored-trailing-bytes
        """

        let parsed = try HTTPRequestParser.parse(Data(request.utf8))

        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/v1beta/models/gemini-2.5-pro:generateContent")
        XCTAssertEqual(parsed.headers["proxy-authorization"], "Basic secret")
        XCTAssertEqual(String(decoding: parsed.body, as: UTF8.self), body)
    }

    func testPlannerForwardsDirectModelsToGoogleWithoutProxyHeaders() throws {
        let body = #"{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}"#
        let request = HTTPRequestEnvelope(
            method: "POST",
            path: "/v1beta/models/gemini-2.5-pro:generateContent",
            httpVersion: "HTTP/1.1",
            headers: ["proxy-authorization": "Basic secret", "content-type": "application/json"],
            body: Data(body.utf8)
        )
        let planner = ProxyRequestPlanner(routingEngine: RoutingEngine(config: .init(routedModels: [])))

        let action = planner.plan(host: "generativelanguage.googleapis.com", request: request)

        guard case let .forwardToGoogle(forwarded, metadata) = action else {
            return XCTFail("expected Google forwarding, got \(action)")
        }
        XCTAssertEqual(metadata.model, "gemini-2.5-pro")
        XCTAssertNil(forwarded.headers["proxy-authorization"])
        XCTAssertEqual(forwarded.headers["content-type"], "application/json")
    }

    func testPlannerRoutesSelectedModelsToCheapRouter() throws {
        let body = #"{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}"#
        let request = HTTPRequestEnvelope(
            method: "POST",
            path: "/v1beta/models/gemini-2.5-pro:streamGenerateContent",
            httpVersion: "HTTP/1.1",
            headers: ["content-type": "application/json"],
            body: Data(body.utf8)
        )
        let planner = ProxyRequestPlanner(routingEngine: RoutingEngine(config: .init(routedModels: ["gemini-2.5-pro"])))

        let action = planner.plan(host: "generativelanguage.googleapis.com", request: request)

        guard case let .routeToCheapRouter(payload, metadata) = action else {
            return XCTFail("expected cheaprouter route, got \(action)")
        }
        XCTAssertEqual(metadata.action, .streamGenerateContent)
        XCTAssertEqual(payload.endpoint, .chatCompletions)
        XCTAssertEqual(payload.model, "gemini-2.5-pro")
        let translated = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
        XCTAssertEqual(translated["model"] as? String, "gemini-2.5-pro")
        XCTAssertEqual(translated["stream"] as? Bool, true)
    }

    func testPlannerFailsClosedWhenRoutedActionIsUnsupported() throws {
        let request = HTTPRequestEnvelope(
            method: "POST",
            path: "/v1beta/models/gemini-2.5-pro:countTokens",
            httpVersion: "HTTP/1.1",
            headers: ["content-type": "application/json"],
            body: Data(#"{"contents":[]}"#.utf8)
        )
        let planner = ProxyRequestPlanner(routingEngine: RoutingEngine(config: .init(routedModels: ["gemini-2.5-pro"])))

        let action = planner.plan(host: "generativelanguage.googleapis.com", request: request)

        XCTAssertEqual(action, .failClosed(reason: .routingFailed(.unsupportedAction)))
    }

    func testPlannerFailsClosedWhenModelCannotBeExtracted() throws {
        let request = HTTPRequestEnvelope(
            method: "POST",
            path: "/v1internal:generateContent",
            httpVersion: "HTTP/1.1",
            headers: ["content-type": "application/json"],
            body: Data(#"{"contents":[]}"#.utf8)
        )
        let planner = ProxyRequestPlanner(routingEngine: RoutingEngine(config: .init(routedModels: ["claude-sonnet-4"])))

        let action = planner.plan(host: "cloudcode-pa.googleapis.com", request: request)

        XCTAssertEqual(action, .failClosed(reason: .modelExtractionFailed))
    }
}
