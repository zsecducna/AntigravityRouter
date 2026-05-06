import XCTest
@testable import AntigravityPorterCore

final class RoutingDecisionTests: XCTestCase {
    func testRoutingDisabledDefaultsDirectForAllModels() {
        let router = RoutingEngine(config: .init(routedModels: []))

        let decision = router.decision(for: .init(client: .antigravity, model: "new-model", action: .generateContent))

        XCTAssertEqual(decision, .googleDirect)
    }

    func testRoutingEnabledClaudeModelUsesMessagesEndpoint() {
        let router = RoutingEngine(config: .init(customProviderRoutingEnabled: true, routedModels: []))

        let decision = router.decision(for: .init(client: .antigravity, model: "claude-sonnet-4", action: .streamGenerateContent))

        XCTAssertEqual(decision, .cheapRouter(endpoint: .messages))
    }

    func testRoutingEnabledNonClaudeModelUsesChatCompletionsEndpoint() {
        let router = RoutingEngine(config: .init(customProviderRoutingEnabled: true, routedModels: []))

        let decision = router.decision(for: .init(client: .antigravity, model: "gpt-5.5", action: .generateContent))

        XCTAssertEqual(decision, .cheapRouter(endpoint: .chatCompletions))
    }

    func testUnsupportedRoutedRequestFailsClosed() {
        let router = RoutingEngine(config: .init(customProviderRoutingEnabled: true, routedModels: [], supportedActions: [.generateContent]))

        let decision = router.decision(for: .init(client: .antigravity, model: "gpt-5.5", action: .countTokens))

        XCTAssertEqual(decision, .failClosed(reason: .unsupportedAction))
    }
}
