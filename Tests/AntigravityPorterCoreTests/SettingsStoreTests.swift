import XCTest
@testable import AntigravityPorterCore

final class SettingsStoreTests: XCTestCase {
    func testDefaultsMatchSafeRoutingContract() {
        let settings = PorterSettings.defaults

        XCTAssertEqual(settings.localProxyHost, "127.0.0.1")
        XCTAssertEqual(settings.localProxyPort, 8877)
        XCTAssertEqual(settings.cheapRouterBaseURL.absoluteString, "https://cheaprouter.uk")
        XCTAssertFalse(settings.customProviderRoutingEnabled)
        XCTAssertTrue(settings.routedModels.isEmpty)
        XCTAssertTrue(settings.rawHTTPLoggingEnabled)
        XCTAssertFalse(settings.unsafeFullRawHTTPLoggingEnabled)
        XCTAssertEqual(settings.logTailLineLimit, 200)
    }

    func testRoutingLabelsDescribeAppEnvRouting() {
        XCTAssertEqual(PorterSettings.routingControlLabel, "Local proxy listener")
        XCTAssertEqual(PorterSettings.proxyListenLabel, "Local proxy")
        XCTAssertEqual(PorterSettings.proxyConnectsLabel, "Proxy CONNECTs today")
        XCTAssertEqual(PorterSettings.targetInferenceConnectsLabel, "Target Google API CONNECTs")
        XCTAssertEqual(PorterSettings.otherHTTPSConnectsLabel, "Other HTTPS CONNECTs")
        XCTAssertEqual(PorterSettings.routedRequestsLabel, "Routed model requests")
        XCTAssertEqual(PorterSettings.directRequestsLabel, "Direct Google model requests")
    }

    func testRouteToggleNormalizesModelIDAndCanDisableRoute() {
        var settings = PorterSettings.defaults

        settings.setRouteViaCheapRouter(true, for: " claude-sonnet-4-6 ")
        XCTAssertTrue(settings.routesViaCheapRouter(modelID: "claude-sonnet-4-6"))

        settings.setRouteViaCheapRouter(false, for: "claude-sonnet-4-6")
        XCTAssertFalse(settings.routesViaCheapRouter(modelID: "claude-sonnet-4-6"))
    }

    func testStoreRoundTripsSettings() throws {
        let storage = InMemorySettingsDataStore()
        let store = UserDefaultsSettingsStore(userDefaults: storage, key: "settings")
        let custom = PorterSettings(
            cheapRouterBaseURL: URL(string: "https://router.example")!,
            localProxyHost: "127.0.0.1",
            localProxyPort: 9999,
            launchAtLoginEnabled: true,
            customProviderRoutingEnabled: true,
            routedModels: [" only-custom "],
            rawHTTPLoggingEnabled: false,
            unsafeFullRawHTTPLoggingEnabled: true,
            logTailLineLimit: 50
        )

        try store.save(custom)
        let loaded = store.load()

        XCTAssertEqual(loaded.cheapRouterBaseURL.absoluteString, "https://router.example")
        XCTAssertEqual(loaded.localProxyPort, 9999)
        XCTAssertEqual(loaded.launchAtLoginEnabled, true)
        XCTAssertTrue(loaded.customProviderRoutingEnabled)
        XCTAssertFalse(loaded.rawHTTPLoggingEnabled)
        XCTAssertTrue(loaded.unsafeFullRawHTTPLoggingEnabled)
        XCTAssertEqual(loaded.logTailLineLimit, 50)
        XCTAssertTrue(loaded.routesViaCheapRouter(modelID: "only-custom"))
    }

    func testLogTailLineLimitIsClamped() {
        let low = PorterSettings(
            cheapRouterBaseURL: URL(string: "https://router.example")!,
            localProxyHost: "127.0.0.1",
            localProxyPort: 9999,
            launchAtLoginEnabled: false,
            routedModels: [],
            logTailLineLimit: 1
        )
        let high = PorterSettings(
            cheapRouterBaseURL: URL(string: "https://router.example")!,
            localProxyHost: "127.0.0.1",
            localProxyPort: 9999,
            launchAtLoginEnabled: false,
            routedModels: [],
            logTailLineLimit: 5000
        )

        XCTAssertEqual(low.logTailLineLimit, 10)
        XCTAssertEqual(high.logTailLineLimit, 1000)
    }

    func testStoreFallsBackToDefaultsForCorruptData() {
        let storage = InMemorySettingsDataStore(storage: ["settings": Data("not json".utf8)])
        let store = UserDefaultsSettingsStore(userDefaults: storage, key: "settings")

        XCTAssertEqual(store.load(), .defaults)
    }
}

final class InMemorySettingsDataStore: SettingsDataStoring, @unchecked Sendable {
    private var storage: [String: Data]

    init(storage: [String: Data] = [:]) {
        self.storage = storage
    }

    func settingsData(forKey key: String) -> Data? {
        storage[key]
    }

    func setSettingsData(_ value: Data, forKey key: String) {
        storage[key] = value
    }

    func removeObject(forKey key: String) {
        storage.removeValue(forKey: key)
    }
}
