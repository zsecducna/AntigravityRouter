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
}
