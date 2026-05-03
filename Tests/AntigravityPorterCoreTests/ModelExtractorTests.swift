import XCTest
@testable import AntigravityPorterCore

final class ModelExtractorTests: XCTestCase {
    func testExtractsGeminiModelAndActionFromURLPath() throws {
        let result = try ModelExtractor.extract(
            host: "generativelanguage.googleapis.com",
            path: "/v1beta/models/gemini-2.5-pro:streamGenerateContent",
            body: Data()
        )

        XCTAssertEqual(result.client, .geminiCLI)
        XCTAssertEqual(result.model, "gemini-2.5-pro")
        XCTAssertEqual(result.action, .streamGenerateContent)
    }

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
        let body = #"{"request":{"payload":{"model":"gemini-2.5-flash"}}}"#.data(using: .utf8)!

        let result = try ModelExtractor.extract(
            host: "daily-cloudcode-pa.googleapis.com",
            path: "/v1internal:countTokens",
            body: body
        )

        XCTAssertEqual(result.model, "gemini-2.5-flash")
        XCTAssertEqual(result.action, .countTokens)
    }
}
