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
}
