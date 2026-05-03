import XCTest
@testable import AntigravityPorterCore

final class RequestLogTests: XCTestCase {
    func testRingBufferKeepsMostRecentEvents() {
        let log = RequestLog(capacity: 3)

        for index in 1...5 {
            log.record(
                method: "POST",
                url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini:generateContent?i=\(index)")!,
                headers: ["X-Request": "\(index)"],
                bodyPreview: "body-\(index)"
            )
        }

        XCTAssertEqual(log.snapshot().map(\.bodyPreview), ["body-3", "body-4", "body-5"])
        XCTAssertEqual(log.totalRecordedCount, 5)
    }

    func testSensitiveHeadersAndBodyPreviewAreRedacted() throws {
        let log = RequestLog()

        log.record(
            method: "POST",
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini:generateContent?key=api-key")!,
            headers: [
                "Authorization": "Bearer google-token",
                "Cookie": "SID=session",
                "X-Goog-Api-Key": "google-key",
                "Content-Type": "application/json"
            ],
            bodyPreview: #"{"access_token":"secret","prompt":"keep out","api_key":"cheaprouter"}"#
        )

        let event = try XCTUnwrap(log.snapshot().last)
        XCTAssertEqual(event.url.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini:generateContent?key=%5BREDACTED%5D")
        XCTAssertEqual(event.headers["Authorization"], "[REDACTED]")
        XCTAssertEqual(event.headers["Cookie"], "[REDACTED]")
        XCTAssertEqual(event.headers["X-Goog-Api-Key"], "[REDACTED]")
        XCTAssertEqual(event.headers["Content-Type"], "application/json")
        XCTAssertFalse(event.bodyPreview.contains("secret"))
        XCTAssertFalse(event.bodyPreview.contains("keep out"))
        XCTAssertFalse(event.bodyPreview.contains("cheaprouter"))
    }
}
