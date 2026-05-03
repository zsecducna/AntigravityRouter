import XCTest
@testable import AntigravityPorterCore

final class CapturePipelineTests: XCTestCase {
    func testSanitizerRedactsSecretHeadersAndJSONFields() throws {
        let capture = CapturedExchange(
            id: "cap-1",
            host: "generativelanguage.googleapis.com",
            path: "/v1beta/models/gemini-2.5-pro:generateContent",
            requestHeaders: ["Authorization": "Bearer google-token", "x-goog-api-key": "abc", "Content-Type": "application/json"],
            requestBody: Data(#"{"access_token":"secret","prompt":"keep"}"#.utf8),
            responseStatus: 200,
            responseHeaders: ["Set-Cookie": "sid=secret"],
            responseBody: Data(#"{"ok":true}"#.utf8),
            timing: .init(startedAt: Date(timeIntervalSince1970: 1), durationMS: 42)
        )

        let sanitized = try CaptureSanitizer().sanitize(capture)

        XCTAssertEqual(sanitized.requestHeaders["Authorization"], "<redacted>")
        XCTAssertEqual(sanitized.requestHeaders["x-goog-api-key"], "<redacted>")
        XCTAssertEqual(sanitized.responseHeaders["Set-Cookie"], "<redacted>")
        XCTAssertFalse(String(decoding: sanitized.requestBody, as: UTF8.self).contains("secret"))
        XCTAssertTrue(String(decoding: sanitized.requestBody, as: UTF8.self).contains("keep"))
    }

    func testManifestMarksUnsanitizedCaptureUnsafeForExport() {
        let manifest = CaptureManifest(
            id: "fixture-pack-1",
            generatedAt: Date(timeIntervalSince1970: 2),
            entries: [
                .init(captureID: "raw", host: "example.com", path: "/unsafe", sanitized: false, durationMS: 10),
                .init(captureID: "clean", host: "example.com", path: "/safe", sanitized: true, durationMS: 11)
            ]
        )

        XCTAssertFalse(manifest.isExportable)
        XCTAssertEqual(manifest.blockingCaptureIDs, ["raw"])
    }
}
