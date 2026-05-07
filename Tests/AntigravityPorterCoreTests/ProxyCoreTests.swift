import XCTest
@testable import AntigravityPorterCore

final class ProxyCoreTests: XCTestCase {
    func testParsesSNIFromTLSClientHello() {
        let hello = makeClientHello(serverName: "cloudcode-pa.googleapis.com")

        XCTAssertEqual(TLSClientHelloParser.serverName(from: hello), "cloudcode-pa.googleapis.com")
    }

    func testTransparentRoutingScriptsStayScopedToAntigravityHosts() {
        let enable = TransparentRoutingScript.enable(proxyPort: 8877)
        let disable = TransparentRoutingScript.disable()

        XCTAssertTrue(enable.contains("cloudcode-pa.googleapis.com"))
        XCTAssertTrue(enable.contains("daily-cloudcode-pa.googleapis.com"))
        XCTAssertTrue(enable.contains("127.0.0.1 cloudcode-pa.googleapis.com"))
        XCTAssertTrue(enable.contains("::ffff:127.0.0.1 cloudcode-pa.googleapis.com"))
        XCTAssertTrue(enable.contains("127.0.0.1 daily-cloudcode-pa.googleapis.com"))
        XCTAssertTrue(enable.contains("::ffff:127.0.0.1 daily-cloudcode-pa.googleapis.com"))
        XCTAssertTrue(enable.contains("port 443 -> 127.0.0.1 port 8877"))
        XCTAssertTrue(enable.contains("rdr-anchor"))
        XCTAssertTrue(enable.contains("/etc/pf.conf"))
        XCTAssertTrue(enable.contains("/etc/pf.anchors/com.antigravityporter"))
        XCTAssertTrue(enable.contains("pfctl -nf"))
        XCTAssertTrue(enable.contains("rollback()"))
        XCTAssertTrue(enable.contains("com.antigravityporter.token"))
        XCTAssertFalse(enable.contains("generativelanguage.googleapis.com"))
        XCTAssertFalse(enable.contains("sandbox-cloudcode-pa.googleapis.com"))
        XCTAssertTrue(disable.contains("pfctl -a com.antigravityporter -F all"))
        XCTAssertTrue(disable.contains("pfctl -X"))
        XCTAssertTrue(disable.contains("AntigravityPorter PF START"))
        XCTAssertTrue(disable.contains("AntigravityPorter START"))
    }

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
        let body = #"{"model":"gpt-5.5","contents":[{"role":"user","parts":[{"text":"hi"}]}]}"#
        let request = """
        POST /v1internal:generateContent HTTP/1.1\r
        Host: cloudcode-pa.googleapis.com\r
        Content-Length: \(body.utf8.count)\r
        Proxy-Authorization: Basic secret\r
        \r
        \(body)ignored-trailing-bytes
        """

        let parsed = try HTTPRequestParser.parse(Data(request.utf8))

        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/v1internal:generateContent")
        XCTAssertEqual(parsed.headers["proxy-authorization"], "Basic secret")
        XCTAssertEqual(String(decoding: parsed.body, as: UTF8.self), body)
    }

    func testParsesChunkedHTTP11RequestBodyBeforePlanning() throws {
        let first = #"{"model":"claude-sonnet-4-6","#
        let second = #""request":{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}}"#
        let request = """
        POST /v1internal:streamGenerateContent?alt=sse HTTP/1.1\r
        Host: 127.0.0.1:8877\r
        Transfer-Encoding: chunked\r
        Content-Type: application/json\r
        \r
        \(String(first.utf8.count, radix: 16))\r
        \(first)\r
        \(String(second.utf8.count, radix: 16));ignored=extension\r
        \(second)\r
        0\r
        \r
        trailing-bytes
        """

        let parsed = try HTTPRequestParser.parse(Data(request.utf8))

        XCTAssertEqual(parsed.path, "/v1internal:streamGenerateContent?alt=sse")
        XCTAssertEqual(parsed.headers["transfer-encoding"], "chunked")
        XCTAssertEqual(String(decoding: parsed.body, as: UTF8.self), first + second)
        let metadata = try ModelExtractor.extract(host: "cloudcode-pa.googleapis.com", path: parsed.path, body: parsed.body)
        XCTAssertEqual(metadata.model, "claude-sonnet-4-6")
    }

    func testChunkedHTTP11RequestWaitsForTerminatingChunk() throws {
        let request = """
        POST /v1internal:streamGenerateContent HTTP/1.1\r
        Host: 127.0.0.1:8877\r
        Transfer-Encoding: chunked\r
        \r
        5\r
        hello\r
        """

        XCTAssertThrowsError(try HTTPRequestParser.parse(Data(request.utf8))) { error in
            XCTAssertEqual(error as? HTTPRequestParseError, .incomplete)
        }
    }

    func testPlannerForwardsDirectModelsToGoogleWithoutProxyHeaders() throws {
        let body = #"{"model":"gpt-5.5","contents":[{"role":"user","parts":[{"text":"hi"}]}]}"#
        let request = HTTPRequestEnvelope(
            method: "POST",
            path: "/v1internal:generateContent",
            httpVersion: "HTTP/1.1",
            headers: ["proxy-authorization": "Basic secret", "content-type": "application/json"],
            body: Data(body.utf8)
        )
        let planner = ProxyRequestPlanner(routingEngine: RoutingEngine(config: .init()))

        let action = planner.plan(host: "cloudcode-pa.googleapis.com", request: request)

        guard case let .forwardToGoogle(forwarded, metadata) = action else {
            return XCTFail("expected Google forwarding, got \(action)")
        }
        XCTAssertEqual(metadata.model, "gpt-5.5")
        XCTAssertNil(forwarded.headers["proxy-authorization"])
        XCTAssertEqual(forwarded.headers["content-type"], "application/json")
    }

    func testPlannerRoutesAllModelsToCheapRouterWhenCustomProviderRoutingEnabled() throws {
        let body = #"{"model":"gpt-5.5","contents":[{"role":"user","parts":[{"text":"hi"}]}]}"#
        let request = HTTPRequestEnvelope(
            method: "POST",
            path: "/v1internal:streamGenerateContent",
            httpVersion: "HTTP/1.1",
            headers: ["content-type": "application/json"],
            body: Data(body.utf8)
        )
        let planner = ProxyRequestPlanner(routingEngine: RoutingEngine(config: .init(customProviderRoutingEnabled: true)))

        let action = planner.plan(host: "cloudcode-pa.googleapis.com", request: request)

        guard case let .routeToCheapRouter(payload, metadata) = action else {
            return XCTFail("expected cheaprouter route, got \(action)")
        }
        XCTAssertEqual(metadata.action, .streamGenerateContent)
        XCTAssertEqual(payload.endpoint, .chatCompletions)
        XCTAssertEqual(payload.model, "gpt-5.5")
        let translated = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
        XCTAssertEqual(translated["model"] as? String, "gpt-5.5")
        XCTAssertEqual(translated["stream"] as? Bool, true)
    }

    func testPlannerRoutesClaudeModelsToCheapRouterWhenCustomProviderRoutingEnabled() throws {
        let body = #"{"model":"claude-sonnet-4-6","request":{"contents":[{"role":"user","parts":[{"text":"hi"}]}],"generationConfig":{"maxOutputTokens":64}}}"#
        let request = HTTPRequestEnvelope(
            method: "POST",
            path: "/v1internal:streamGenerateContent",
            httpVersion: "HTTP/1.1",
            headers: ["content-type": "application/json"],
            body: Data(body.utf8)
        )
        let planner = ProxyRequestPlanner(routingEngine: RoutingEngine(config: .init(customProviderRoutingEnabled: true)))

        let action = planner.plan(host: "cloudcode-pa.googleapis.com", request: request)

        guard case let .routeToCheapRouter(payload, metadata) = action else {
            return XCTFail("expected cheaprouter route, got \(action)")
        }
        XCTAssertEqual(metadata.model, "claude-sonnet-4-6")
        XCTAssertEqual(payload.endpoint, .messages)
    }

    func testPlannerFailsClosedWhenRoutedActionIsUnsupported() throws {
        let request = HTTPRequestEnvelope(
            method: "POST",
            path: "/v1internal:countTokens",
            httpVersion: "HTTP/1.1",
            headers: ["content-type": "application/json"],
            body: Data(#"{"model":"gpt-5.5","contents":[]}"#.utf8)
        )
        let planner = ProxyRequestPlanner(routingEngine: RoutingEngine(config: .init(customProviderRoutingEnabled: true)))

        let action = planner.plan(host: "cloudcode-pa.googleapis.com", request: request)

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
        let planner = ProxyRequestPlanner(routingEngine: RoutingEngine(config: .init()))

        let action = planner.plan(host: "cloudcode-pa.googleapis.com", request: request)

        XCTAssertEqual(action, .failClosed(reason: .modelExtractionFailed))
    }

    func testNormalizedForClientStripsEncodingHeadersAndSetsContentLength() {
        let body = Data("hello world".utf8)
        let response = ProxyHTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Encoding": "gzip",
                "content-length": "999",
                "Transfer-Encoding": "chunked",
                "Connection": "keep-alive",
                "Content-Type": "application/json",
                "Content-MD5": "abc123"
            ],
            body: body
        )

        let normalized = response.normalizedForClient()

        let lowercasedKeys = Set(normalized.headers.keys.map { $0.lowercased() })
        XCTAssertFalse(lowercasedKeys.contains("content-encoding"))
        XCTAssertFalse(lowercasedKeys.contains("transfer-encoding"))
        XCTAssertFalse(lowercasedKeys.contains("content-md5"))
        XCTAssertTrue(lowercasedKeys.contains("content-type"))
        XCTAssertEqual(normalized.headers["Content-Length"], "\(body.count)")
        XCTAssertEqual(normalized.headers["Connection"], "close")
        XCTAssertEqual(normalized.statusCode, 200)
        XCTAssertEqual(normalized.body, body)
    }

    // MARK: - Phase 0 behavior inventory stubs
    // These stub out observable runtime behaviors not yet covered by Core unit tests.
    // Each must be implemented when App transport (Phase 3) is in place.

    func testDirectTLSClientHelloRoutingDecisionBySNI() {
        // Behavior: raw TLS ClientHello on interceptable SNI → ConnectionRoutingDecision.directTLS
        let matrix = ConnectionRoutingMatrix()
        let info = ClientHelloInfo(sni: "cloudcode-pa.googleapis.com", alpn: ["http/1.1"])
        let decision = matrix.decision(for: .tlsClientHello(info: info))
        XCTAssertEqual(decision, .directTLS)
    }

    func testCONNECTMITMTargetInferenceHostProducesConnectMITMDecision() {
        // Behavior: CONNECT to target-inference host → connectMITM
        let matrix = ConnectionRoutingMatrix()
        let decision = matrix.decision(for: .connectRequest(host: "cloudcode-pa.googleapis.com", port: 443))
        XCTAssertEqual(decision, .connectMITM(host: "cloudcode-pa.googleapis.com"))
    }

    func testCONNECTBlindTunnelHostProducesBlindTunnelDecision() {
        // Behavior: CONNECT to excluded host → blindTunnel
        let matrix = ConnectionRoutingMatrix()
        let decision = matrix.decision(for: .connectRequest(host: "oauth2.googleapis.com", port: 443))
        XCTAssertEqual(decision, .blindTunnel)
    }

    func testCONNECTToNonTLSPortProducesRejectDecision() {
        // Behavior: CONNECT to port != 443 → reject
        let matrix = ConnectionRoutingMatrix()
        let decision = matrix.decision(for: .connectRequest(host: "example.com", port: 80))
        if case .reject = decision { /* pass */ } else {
            XCTFail("expected reject, got \(decision)")
        }
    }

    func testPACRequestPathProducesPACRequestDecision() {
        // Behavior: plain HTTP GET /proxy.pac → pacRequest
        let matrix = ConnectionRoutingMatrix()
        let decision = matrix.decision(for: .httpRequest(method: "GET", path: "/proxy.pac", host: "proxy.local"))
        XCTAssertEqual(decision, .pacRequest)
    }

    func testMalformedSignalProducesRejectDecision() {
        // Behavior: unrecognisable initial bytes → reject
        let matrix = ConnectionRoutingMatrix()
        let decision = matrix.decision(for: .malformed)
        if case .reject = decision { /* pass */ } else {
            XCTFail("expected reject, got \(decision)")
        }
    }

    func testCONNECTMITMSends200ConnectionEstablishedBeforeTLS() {
        XCTAssertEqual(
            String(decoding: ProxyWireProtocol.connectEstablished, as: UTF8.self),
            "HTTP/1.1 200 Connection Established\r\n\r\n"
        )
    }

    func testCONNECTBlindTunnelRelaysDataOpaquely() {
        var replay = InitialReplayBuffer(buffered: Data("early-bytes".utf8))
        XCTAssertEqual(
            String(decoding: replay.prepend(to: Data("-next".utf8)), as: UTF8.self),
            "early-bytes-next"
        )
        XCTAssertTrue(replay.isDrained)
    }

    func testCONNECTRejectPathReturnsErrorStatusAndCloses() {
        let response = ProxyWireProtocol.plainHTTPResponse(
            status: "403 Forbidden",
            body: Data("403 Forbidden".utf8)
        )
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 13\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n403 Forbidden"))
    }

    func testPACRequestReturnsPACScriptBodyAndCloses() {
        let script = "function FindProxyForURL(url, host) { return 'DIRECT'; }"
        let response = ProxyWireProtocol.pacResponse(method: "GET", script: script)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/x-ns-proxy-autoconfig\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n\(script)"))

        let headResponse = ProxyWireProtocol.pacResponse(method: "HEAD", script: script)
        XCTAssertTrue(String(decoding: headResponse, as: UTF8.self).hasSuffix("\r\n\r\n"))
    }

    func testListenerBindsOnBothIPv4AndIPv6() {
        XCTAssertEqual(ProxyListenerPlan.loopbackHosts(for: "127.0.0.1"), ["127.0.0.1", "::1"])
        XCTAssertEqual(ProxyListenerPlan.loopbackHosts(for: "localhost"), ["127.0.0.1", "::1"])
        XCTAssertEqual(ProxyListenerPlan.loopbackHosts(for: "0.0.0.0"), ["0.0.0.0"])
    }

    func testTimeoutPathProducesDeterministicCleanupAndLog() {
        let cleanup = ProxyCleanupPlan(logPhase: "tls-handshake")
        XCTAssertTrue(cleanup.closesClient)
        XCTAssertTrue(cleanup.closesRelay)
        XCTAssertTrue(cleanup.closesTLSConnection)
        XCTAssertTrue(cleanup.closesTLSListener)
        XCTAssertEqual(cleanup.logPhase, "tls-handshake")
    }

    private func makeClientHello(serverName: String) -> Data {
        let name = Array(serverName.utf8)
        let serverNameEntry = [UInt8(0), UInt8((name.count >> 8) & 0xff), UInt8(name.count & 0xff)] + name
        let serverNameListLength = serverNameEntry.count
        let sniBody = [UInt8((serverNameListLength >> 8) & 0xff), UInt8(serverNameListLength & 0xff)] + serverNameEntry
        let sniExtension = [UInt8(0), UInt8(0), UInt8((sniBody.count >> 8) & 0xff), UInt8(sniBody.count & 0xff)] + sniBody
        let extensionsLength = sniExtension.count
        let handshakeBody: [UInt8] =
            [0x03, 0x03] +
            Array(repeating: UInt8(0), count: 32) +
            [0] +
            [0, 2, 0x13, 0x01] +
            [1, 0] +
            [UInt8((extensionsLength >> 8) & 0xff), UInt8(extensionsLength & 0xff)] +
            sniExtension
        let handshakeLength = handshakeBody.count
        let handshake = [UInt8(0x01), UInt8((handshakeLength >> 16) & 0xff), UInt8((handshakeLength >> 8) & 0xff), UInt8(handshakeLength & 0xff)] + handshakeBody
        let recordLength = handshake.count
        return Data([0x16, 0x03, 0x01, UInt8((recordLength >> 8) & 0xff), UInt8(recordLength & 0xff)] + handshake)
    }
}
