import XCTest
@testable import AntigravityPorterCore

final class HostPolicyTests: XCTestCase {
    func testExcludedGoogleAuthHostsAreBlindTunneled() {
        let policy = HostPolicy.default

        XCTAssertEqual(policy.decision(for: "oauth2.googleapis.com", port: 443, path: nil), .blindTunnel)
        XCTAssertEqual(policy.decision(for: "accounts.google.com", port: 443, path: nil), .blindTunnel)
        XCTAssertEqual(policy.decision(for: "www.googleapis.com", port: 443, path: nil), .blindTunnel)
    }

    func testCheapRouterBypassesLocalProxyToAvoidLoops() {
        let policy = HostPolicy.default

        XCTAssertEqual(policy.decision(for: "cheaprouter.uk", port: 443, path: nil), .blindTunnel)
    }

    func testAntigravityInferenceHostsAreInterceptedOnlyForKnownPaths() {
        let policy = HostPolicy.default

        XCTAssertEqual(
            policy.decision(for: "cloudcode-pa.googleapis.com", port: 443, path: "/v1internal:streamGenerateContent"),
            .intercept
        )
        XCTAssertEqual(
            policy.decision(for: "daily-cloudcode-pa.googleapis.com", port: 443, path: "/v1internal:generateContent"),
            .intercept
        )
        XCTAssertEqual(
            policy.decision(for: "sandbox-cloudcode-pa.googleapis.com", port: 443, path: "/v1internal:countTokens"),
            .intercept
        )
        XCTAssertEqual(
            policy.decision(for: "cloudcode-pa.googleapis.com", port: 443, path: "/oauth/token"),
            .blindTunnel
        )
    }

    func testGeminiInferenceHostIsInterceptedOnlyForGenerateAndTokenActions() {
        let policy = HostPolicy.default

        XCTAssertEqual(
            policy.decision(for: "generativelanguage.googleapis.com", port: 443, path: "/v1beta/models/gemini-2.5-pro:streamGenerateContent"),
            .intercept
        )
        XCTAssertEqual(
            policy.decision(for: "generativelanguage.googleapis.com", port: 443, path: "/v1beta/models/gemini-2.5-pro:generateContent?alt=sse"),
            .intercept
        )
        XCTAssertEqual(
            policy.decision(for: "generativelanguage.googleapis.com", port: 443, path: "/v1beta/files"),
            .blindTunnel
        )
    }
}
