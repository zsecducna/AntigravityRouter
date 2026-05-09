import XCTest
@testable import AntigravityRouterCore

final class ModelExtractorTests: XCTestCase {
    func testExtractsAntigravityTopLevelModel() throws {
        let body = #"{"model":"claude-sonnet-4","contents":[{"role":"user"}]}"#.data(using: .utf8)!

        let result = try ModelExtractor.extract(
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:generateContent",
            body: body
        )

        XCTAssertEqual(result.client, .antigravity)
        XCTAssertEqual(result.model, "claude-sonnet-4")
        XCTAssertEqual(result.action, .generateContent)
    }

    func testExtractsAntigravityNestedModel() throws {
        let body = #"{"request":{"payload":{"model":"claude-sonnet-4-6"}}}"#.data(using: .utf8)!

        let result = try ModelExtractor.extract(
            host: "daily-cloudcode-pa.googleapis.com",
            path: "/v1internal:countTokens",
            body: body
        )

        XCTAssertEqual(result.client, .antigravity)
        XCTAssertEqual(result.model, "claude-sonnet-4-6")
        XCTAssertEqual(result.action, .countTokens)
    }
}
