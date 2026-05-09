import XCTest
@testable import AntigravityRouterCore

final class SettingsStoreTests: XCTestCase {
    func testDefaultsMatchSafeRoutingContract() {
        let settings = PorterSettings.defaults

        XCTAssertEqual(settings.localProxyHost, "127.0.0.1")
        XCTAssertEqual(settings.localProxyPort, 8877)
        XCTAssertEqual(settings.cheapRouterBaseURL.absoluteString, "https://cheaprouter.uk")
        XCTAssertFalse(settings.customProviderRoutingEnabled)
        XCTAssertTrue(settings.rawHTTPLoggingEnabled)
        XCTAssertFalse(settings.unsafeFullRawHTTPLoggingEnabled)
        XCTAssertEqual(settings.logTailLineLimit, 200)
        XCTAssertEqual(settings.providerModelAliases, [:])
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

    func testStoreRoundTripsSettings() throws {
        let storage = InMemorySettingsDataStore()
        let store = UserDefaultsSettingsStore(userDefaults: storage, key: "settings")
        let custom = PorterSettings(
            cheapRouterBaseURL: URL(string: "https://router.example")!,
            localProxyHost: "127.0.0.1",
            localProxyPort: 9999,
            launchAtLoginEnabled: true,
            customProviderRoutingEnabled: true,
            rawHTTPLoggingEnabled: false,
            unsafeFullRawHTTPLoggingEnabled: true,
            logTailLineLimit: 50,
            providerModelAliases: ["MODEL_PLACEHOLDER_M120": "gpt-5.5"]
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
        XCTAssertEqual(loaded.providerModelAliases, ["MODEL_PLACEHOLDER_M120": "gpt-5.5"])
    }

    func testLegacyRoutedModelsEnableCustomProviderRouting() throws {
        let storage = InMemorySettingsDataStore(storage: [
            "settings": Data(
                #"""
                {
                  "cheapRouterBaseURL": "https://router.example",
                  "localProxyHost": "127.0.0.1",
                  "localProxyPort": 8877,
                  "launchAtLoginEnabled": false,
                  "routedModels": ["gpt-5.5"]
                }
                """#.utf8
            )
        ])
        let store = UserDefaultsSettingsStore(userDefaults: storage, key: "settings")

        let loaded = store.load()

        XCTAssertTrue(loaded.customProviderRoutingEnabled)
    }

    func testExplicitCustomProviderRoutingFlagWinsOverLegacyRoutedModels() throws {
        let storage = InMemorySettingsDataStore(storage: [
            "settings": Data(
                #"""
                {
                  "cheapRouterBaseURL": "https://router.example",
                  "localProxyHost": "127.0.0.1",
                  "localProxyPort": 8877,
                  "launchAtLoginEnabled": false,
                  "customProviderRoutingEnabled": false,
                  "routedModels": ["gpt-5.5"]
                }
                """#.utf8
            )
        ])
        let store = UserDefaultsSettingsStore(userDefaults: storage, key: "settings")

        let loaded = store.load()

        XCTAssertFalse(loaded.customProviderRoutingEnabled)
    }

    func testLogTailLineLimitIsClamped() {
        let low = PorterSettings(
            cheapRouterBaseURL: URL(string: "https://router.example")!,
            localProxyHost: "127.0.0.1",
            localProxyPort: 9999,
            launchAtLoginEnabled: false,
            logTailLineLimit: 1
        )
        let high = PorterSettings(
            cheapRouterBaseURL: URL(string: "https://router.example")!,
            localProxyHost: "127.0.0.1",
            localProxyPort: 9999,
            launchAtLoginEnabled: false,
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

    func testUnsafeFullRawLoggingIsDisabledForNewLaunch() {
        var settings = PorterSettings.defaults
        settings.unsafeFullRawHTTPLoggingEnabled = true

        let sanitized = settings.disablingUnsafeFullRawHTTPLoggingForNewLaunch()

        XCTAssertFalse(sanitized.unsafeFullRawHTTPLoggingEnabled)
        XCTAssertTrue(settings.unsafeFullRawHTTPLoggingEnabled)
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
