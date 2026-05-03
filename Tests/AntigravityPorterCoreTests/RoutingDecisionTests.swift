import XCTest
@testable import AntigravityPorterCore

final class RoutingDecisionTests: XCTestCase {
    func testUnknownModelDefaultsDirect() {
        let router = RoutingEngine(config: .init(routedModels: []))

        let decision = router.decision(for: .init(client: .geminiCLI, model: "new-model", action: .generateContent))

        XCTAssertEqual(decision, .googleDirect)
    }

    func testRoutedClaudeModelUsesMessagesEndpoint() {
        let router = RoutingEngine(config: .init(routedModels: ["claude-sonnet-4"]))

        let decision = router.decision(for: .init(client: .antigravity, model: "claude-sonnet-4", action: .streamGenerateContent))

        XCTAssertEqual(decision, .cheapRouter(endpoint: .messages))
    }

    func testRoutedNonClaudeModelUsesChatCompletionsEndpoint() {
        let router = RoutingEngine(config: .init(routedModels: ["gemini-2.5-pro"]))

        let decision = router.decision(for: .init(client: .geminiCLI, model: "gemini-2.5-pro", action: .generateContent))

        XCTAssertEqual(decision, .cheapRouter(endpoint: .chatCompletions))
    }

    func testUnsupportedRoutedRequestFailsClosed() {
        let router = RoutingEngine(config: .init(routedModels: ["gemini-2.5-pro"], supportedActions: [.generateContent]))

        let decision = router.decision(for: .init(client: .geminiCLI, model: "gemini-2.5-pro", action: .countTokens))

        XCTAssertEqual(decision, .failClosed(reason: .unsupportedAction))
    }
}
