import XCTest
@testable import AntigravityPorterCore

final class PACScriptTests: XCTestCase {
    func testPACRoutesOnlyInferenceHostsToLocalProxy() {
        let script = PACScript.generate(proxyHost: "127.0.0.1", proxyPort: 8877)

        XCTAssertTrue(script.contains("function FindProxyForURL"))
        XCTAssertTrue(script.contains("cloudcode-pa.googleapis.com"))
        XCTAssertTrue(script.contains("daily-cloudcode-pa.googleapis.com"))
        XCTAssertFalse(script.contains("sandbox-cloudcode-pa.googleapis.com"))
        XCTAssertFalse(script.contains("generativelanguage.googleapis.com"))
        XCTAssertTrue(script.contains("PROXY 127.0.0.1:8877"))
        XCTAssertTrue(script.contains("DIRECT"))
        XCTAssertFalse(script.contains("oauth2.googleapis.com"))
        XCTAssertFalse(script.contains("accounts.google.com"))
        XCTAssertFalse(script.contains("cheaprouter.uk"))
    }

    func testProxyEnvironmentBypassesGoogleOAuthAndAccountHosts() {
        let variables = ProxyEnvironment.variables(proxyHost: "127.0.0.1", proxyPort: 8877)

        XCTAssertEqual(variables["HTTPS_PROXY"], "http://127.0.0.1:8877")
        XCTAssertTrue(ProxyEnvironment.noProxyList.contains("accounts.google.com"))
        XCTAssertTrue(ProxyEnvironment.noProxyList.contains("oauth2.googleapis.com"))
        XCTAssertTrue(ProxyEnvironment.noProxyList.contains("www.googleapis.com"))
        XCTAssertTrue(ProxyEnvironment.noProxyList.contains(".google.com"))
        XCTAssertTrue(ProxyEnvironment.chromiumBypassList.contains("accounts.google.com"))
        XCTAssertTrue(ProxyEnvironment.chromiumBypassList.contains("oauth2.googleapis.com"))
        XCTAssertTrue(ProxyEnvironment.chromiumBypassList.contains("*.google.com"))
        XCTAssertFalse(ProxyEnvironment.chromiumBypassList.contains("cloudcode-pa.googleapis.com"))
    }
}
