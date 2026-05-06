import XCTest
@testable import AntigravityPorterCore

final class CapturePipelineTests: XCTestCase {
    func testSanitizerRedactsSecretHeadersAndJSONFields() throws {
        let capture = CapturedExchange(
            id: "cap-1",
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:generateContent",
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

    func testFixtureStoreWritesOnlySanitizedExportablePacks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AntigravityPorterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = CapturedExchange(
            id: "cap/secret",
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:generateContent",
            requestHeaders: ["Authorization": "Bearer google-token"],
            requestBody: Data(#"{"api_key":"secret","contents":[{"role":"user","parts":[{"text":"hello"}]}]}"#.utf8),
            responseStatus: 200,
            responseHeaders: ["Set-Cookie": "sid=secret"],
            responseBody: Data(#"{"ok":true}"#.utf8),
            timing: .init(startedAt: Date(timeIntervalSince1970: 3), durationMS: 14)
        )

        let manifest = try CaptureFixtureStore().writeSanitizedPack(
            captures: [capture],
            to: directory,
            manifestID: "pack",
            generatedAt: Date(timeIntervalSince1970: 4)
        )
        let pack = try CaptureFixtureStore().readPack(from: directory)

        XCTAssertTrue(manifest.isExportable)
        XCTAssertEqual(pack.manifest.id, "pack")
        XCTAssertEqual(pack.captures.map(\.id), ["cap/secret"])
        XCTAssertEqual(pack.captures[0].requestHeaders["Authorization"], "<redacted>")
        XCTAssertFalse(String(decoding: pack.captures[0].requestBody, as: UTF8.self).contains(#""secret""#))
    }

    func testReplayHarnessRoutesCapturedFixtureThroughPlanner() throws {
        let capture = CapturedExchange(
            id: "antigravity-stream",
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:streamGenerateContent",
            requestHeaders: ["content-type": "application/json"],
            requestBody: Data(#"{"model":"gpt-5.5","contents":[{"role":"user","parts":[{"text":"hello"}]}],"generationConfig":{"maxOutputTokens":128}}"#.utf8),
            responseStatus: 200,
            responseHeaders: [:],
            responseBody: Data(),
            timing: .init(startedAt: Date(timeIntervalSince1970: 5), durationMS: 20)
        )
        let harness = ReplayHarness(planner: ProxyRequestPlanner(
            routingEngine: RoutingEngine(config: .init(customProviderRoutingEnabled: true, routedModels: []))
        ))

        let result = harness.replay(capture)

        guard case let .routeToCheapRouter(payload, metadata) = result.action else {
            return XCTFail("expected cheaprouter route, got \(result.action)")
        }
        XCTAssertEqual(result.captureID, "antigravity-stream")
        XCTAssertEqual(metadata.model, "gpt-5.5")
        XCTAssertEqual(payload.endpoint, .chatCompletions)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-5.5")
        XCTAssertEqual(json["max_tokens"] as? Int, 128)
    }

    func testReplayHarnessKeepsUnsupportedRoutedFixtureFailClosed() {
        let capture = CapturedExchange(
            id: "antigravity-count",
            host: "cloudcode-pa.googleapis.com",
            path: "/v1internal:countTokens",
            requestHeaders: ["content-type": "application/json"],
            requestBody: Data(#"{"model":"gpt-5.5","contents":[{"role":"user","parts":[{"text":"hello"}]}]}"#.utf8),
            responseStatus: 200,
            responseHeaders: [:],
            responseBody: Data(),
            timing: .init(startedAt: Date(timeIntervalSince1970: 6), durationMS: 22)
        )
        let harness = ReplayHarness(planner: ProxyRequestPlanner(
            routingEngine: RoutingEngine(config: .init(customProviderRoutingEnabled: true, routedModels: []))
        ))

        let result = harness.replay(capture)

        XCTAssertEqual(result.action, .failClosed(reason: .routingFailed(.unsupportedAction)))
    }
}
