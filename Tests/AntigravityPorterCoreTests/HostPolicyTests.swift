import XCTest
@testable import AntigravityPorterCore

final class HostPolicyTests: XCTestCase {
    func testConnectTargetPolicyTunnelsUnknownHTTPSHostsForAppScopedProxyMode() {
        let policy = ConnectTargetPolicy.default

        XCTAssertEqual(policy.decision(for: "updates.antigravity.google.com", port: 443), .blindTunnel)
        XCTAssertEqual(policy.decision(for: "accounts.google.com", port: 443), .blindTunnel)
        XCTAssertEqual(policy.decision(for: "cheaprouter.uk", port: 443), .blindTunnel)
        XCTAssertEqual(policy.decision(for: "example.com", port: 80), .reject)
    }

    func testConnectTargetPolicyMarksInferenceHostsForLoggingAndFutureMitm() {
        let policy = ConnectTargetPolicy.default

        XCTAssertEqual(policy.decision(for: "cloudcode-pa.googleapis.com", port: 443), .targetInference)
        XCTAssertEqual(policy.decision(for: "daily-cloudcode-pa.googleapis.com", port: 443), .targetInference)
        XCTAssertEqual(policy.decision(for: "sandbox-cloudcode-pa.googleapis.com", port: 443), .blindTunnel)
        XCTAssertEqual(policy.decision(for: "generativelanguage.googleapis.com", port: 443), .blindTunnel)
        XCTAssertEqual(policy.decision(for: "oauth2.googleapis.com", port: 443), .blindTunnel)
    }

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
            policy.decision(for: "cloudcode-pa.googleapis.com", port: 443, path: "/v1internal:countTokens"),
            .blindTunnel
        )
        XCTAssertEqual(
            policy.decision(for: "cloudcode-pa.googleapis.com", port: 443, path: "/v1internal:fetchAvailableModels"),
            .intercept
        )
        XCTAssertEqual(
            policy.decision(for: "sandbox-cloudcode-pa.googleapis.com", port: 443, path: "/v1internal:countTokens"),
            .blindTunnel
        )
        XCTAssertEqual(
            policy.decision(for: "cloudcode-pa.googleapis.com", port: 443, path: "/oauth/token"),
            .blindTunnel
        )
    }

    func testGenerativeLanguageHostIsBlindTunneledBecauseV1IsAntigravityOnly() {
        let policy = HostPolicy.default

        XCTAssertEqual(
            policy.decision(for: "generativelanguage.googleapis.com", port: 443, path: "/v1beta/models/some-model:streamGenerateContent"),
            .blindTunnel
        )
        XCTAssertEqual(
            policy.decision(for: "generativelanguage.googleapis.com", port: 443, path: "/v1beta/models/some-model:generateContent?alt=sse"),
            .blindTunnel
        )
        XCTAssertEqual(
            policy.decision(for: "generativelanguage.googleapis.com", port: 443, path: "/v1beta/files"),
            .blindTunnel
        )
    }

    func testCloudCodeProdHostRewritesToDailyUpstream() {
        XCTAssertEqual(
            GoogleUpstreamHostPolicy.host(for: "cloudcode-pa.googleapis.com"),
            "daily-cloudcode-pa.googleapis.com"
        )
        XCTAssertEqual(
            GoogleUpstreamHostPolicy.host(for: "daily-cloudcode-pa.googleapis.com"),
            "daily-cloudcode-pa.googleapis.com"
        )
        XCTAssertEqual(
            GoogleUpstreamHostPolicy.host(for: "generativelanguage.googleapis.com"),
            "generativelanguage.googleapis.com"
        )
    }
}
