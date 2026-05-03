import XCTest
@testable import AntigravityPorterCore

final class SettingsStoreTests: XCTestCase {
    func testDefaultsMatchSafeRoutingContract() {
        let settings = PorterSettings.defaults

        XCTAssertEqual(settings.localProxyHost, "127.0.0.1")
        XCTAssertEqual(settings.localProxyPort, 8877)
        XCTAssertEqual(settings.cheapRouterBaseURL.absoluteString, "https://cheaprouter.uk")
        XCTAssertTrue(settings.routedModels.isEmpty)
        XCTAssertTrue(settings.knownModels.contains(.init(id: "gemini-2.5-pro", source: .builtIn)))
        XCTAssertTrue(settings.knownModels.contains(.init(id: "claude-sonnet-4", source: .builtIn)))
    }

    func testSeenModelsAreAddedDirectByDefault() {
        var settings = PorterSettings.defaults
        let seenAt = Date(timeIntervalSince1970: 12)

        XCTAssertTrue(settings.registerSeenModel("new-model", at: seenAt))
        XCTAssertFalse(settings.registerSeenModel("new-model", at: seenAt))

        XCTAssertTrue(settings.knownModels.contains(.init(id: "new-model", source: .seenInTraffic, firstSeenAt: seenAt)))
        XCTAssertFalse(settings.routesViaCheapRouter(modelID: "new-model"))
    }

    func testRouteToggleAddsManualModelAndCanDisableRoute() {
        var settings = PorterSettings.defaults

        settings.setRouteViaCheapRouter(true, for: "custom-claude")
        XCTAssertTrue(settings.routesViaCheapRouter(modelID: "custom-claude"))
        XCTAssertTrue(settings.knownModels.contains(.init(id: "custom-claude", source: .manual)))

        settings.setRouteViaCheapRouter(false, for: "custom-claude")
        XCTAssertFalse(settings.routesViaCheapRouter(modelID: "custom-claude"))
    }

    func testStoreRoundTripsSettingsAndMergesMissingBuiltIns() throws {
        let storage = InMemorySettingsDataStore()
        let store = UserDefaultsSettingsStore(userDefaults: storage, key: "settings")
        let custom = PorterSettings(
            cheapRouterBaseURL: URL(string: "https://router.example")!,
            localProxyHost: "127.0.0.1",
            localProxyPort: 9999,
            launchAtLoginEnabled: true,
            knownModels: [.init(id: "only-custom", source: .manual)],
            routedModels: ["only-custom"]
        )

        try store.save(custom)
        let loaded = store.load()

        XCTAssertEqual(loaded.cheapRouterBaseURL.absoluteString, "https://router.example")
        XCTAssertEqual(loaded.localProxyPort, 9999)
        XCTAssertEqual(loaded.launchAtLoginEnabled, true)
        XCTAssertTrue(loaded.routesViaCheapRouter(modelID: "only-custom"))
        XCTAssertTrue(loaded.knownModels.contains(.init(id: "gemini-2.5-pro", source: .builtIn)))
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
