import XCTest
@testable import AntigravityRouterCore

final class RoutingDecisionTests: XCTestCase {
    func testRoutingDisabledDefaultsDirectForAllModels() {
        let router = RoutingEngine(config: .init())

        let decision = router.decision(for: .init(client: .antigravity, model: "new-model", action: .generateContent))

        XCTAssertEqual(decision, .googleDirect)
    }

    func testRoutingEnabledGoogleCatalogModelStaysDirect() {
        let router = RoutingEngine(config: .init(customProviderRoutingEnabled: true, providerModelAliases: ["gpt-5.5": "gpt-5.5"]))

        let decision = router.decision(for: .init(client: .antigravity, model: "claude-sonnet-4-6-thinking", action: .streamGenerateContent))

        XCTAssertEqual(decision, .googleDirect)
    }

    func testRoutingEnabledProviderModelUsesResponsesEndpoint() {
        let router = RoutingEngine(config: .init(customProviderRoutingEnabled: true, providerModelAliases: ["gpt-5.5": "gpt-5.5"]))

        let decision = router.decision(for: .init(client: .antigravity, model: "gpt-5.5", action: .generateContent))

        XCTAssertEqual(decision, .cheapRouter(endpoint: .responses, providerID: "cheaprouter"))
    }

    func testRoutingEnabledProviderPlaceholderResolvesToProviderModel() {
        let router = RoutingEngine(config: .init(customProviderRoutingEnabled: true, providerModelAliases: ["MODEL_PLACEHOLDER_M120": "gpt-5.5"]))
        let metadata = ModelRequestMetadata(client: .antigravity, model: "MODEL_PLACEHOLDER_M120", action: .streamGenerateContent)

        XCTAssertEqual(router.decision(for: metadata), .cheapRouter(endpoint: .responses, providerID: "cheaprouter"))
        XCTAssertEqual(router.resolvedMetadata(for: metadata).model, "gpt-5.5")
    }

    func testRoutingCarriesProviderIDAndStripsDisplayPrefix() {
        let router = RoutingEngine(config: .init(customProviderRoutingEnabled: true, providerModelAliases: [
            "openai/gpt-5.5": ProviderModelAlias(providerID: "openai", modelID: "gpt-5.5")
        ]))
        let metadata = ModelRequestMetadata(client: .antigravity, model: "openai/gpt-5.5", action: .generateContent)

        XCTAssertEqual(router.decision(for: metadata), .cheapRouter(endpoint: .responses, providerID: "openai"))
        XCTAssertEqual(router.resolvedMetadata(for: metadata).model, "gpt-5.5")
    }

    func testUnknownProviderPlaceholderFailsClosedInsteadOfForwardingToGoogle() {
        let router = RoutingEngine(config: .init(customProviderRoutingEnabled: true, providerModelAliases: [:]))

        let decision = router.decision(for: .init(client: .antigravity, model: "MODEL_PLACEHOLDER_M120", action: .generateContent))

        XCTAssertEqual(decision, .failClosed(reason: .unsupportedModel))
    }

    func testUnsupportedRoutedRequestFailsClosed() {
        let router = RoutingEngine(config: .init(customProviderRoutingEnabled: true, supportedActions: [.generateContent], providerModelAliases: ["gpt-5.5": "gpt-5.5"]))

        let decision = router.decision(for: .init(client: .antigravity, model: "gpt-5.5", action: .countTokens))

        XCTAssertEqual(decision, .failClosed(reason: .unsupportedAction))
    }

    func testUnsupportedGoogleCatalogRequestStillStaysDirect() {
        let router = RoutingEngine(config: .init(customProviderRoutingEnabled: true, supportedActions: [.generateContent], providerModelAliases: ["gpt-5.5": "gpt-5.5"]))

        let decision = router.decision(for: .init(client: .antigravity, model: "gemini-3.1-pro-high", action: .countTokens))

        XCTAssertEqual(decision, .googleDirect)
    }
}
