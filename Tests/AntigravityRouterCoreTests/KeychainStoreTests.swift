import XCTest
@testable import AntigravityRouterCore

final class KeychainStoreTests: XCTestCase {
    func testInMemoryStoreRoundTripsApiKeyAndCAIdentityMaterial() throws {
        let store = InMemoryKeychainStore()

        try store.setString("cr_sk_live_secret", for: .cheapRouterAPIKey)
        try store.setData(Data([0xCA, 0xFE]), for: .certificateAuthorityPrivateKey)

        XCTAssertEqual(try store.string(for: .cheapRouterAPIKey), "cr_sk_live_secret")
        XCTAssertEqual(try store.data(for: .certificateAuthorityPrivateKey), Data([0xCA, 0xFE]))
    }

    func testDeleteRemovesOnlyRequestedSecret() throws {
        let store = InMemoryKeychainStore()

        try store.setString("cr_sk_live_secret", for: .cheapRouterAPIKey)
        try store.setData(Data([0x01]), for: .certificateAuthorityPrivateKey)
        try store.delete(.cheapRouterAPIKey)

        XCTAssertNil(try store.string(for: .cheapRouterAPIKey))
        XCTAssertEqual(try store.data(for: .certificateAuthorityPrivateKey), Data([0x01]))
    }

    func testSecretKeysDoNotExposeSecretValuesInDescriptions() throws {
        let store = InMemoryKeychainStore()

        try store.setString("cr_sk_live_secret", for: .cheapRouterAPIKey)

        XCTAssertFalse(String(describing: store).contains("cr_sk_live_secret"))
        XCTAssertEqual(String(describing: KeychainSecretKey.cheapRouterAPIKey), "cheapRouterAPIKey")
    }

    func testSecurityBackedStoreRoundTripsAndDeletesFromScopedService() throws {
        let store = SecurityKeychainStore(service: "AntigravityRouterTests.\(UUID().uuidString)")
        defer {
            try? store.delete(.cheapRouterAPIKey)
            try? store.delete(.certificateAuthorityPrivateKey)
        }

        try store.setString("secret", for: .cheapRouterAPIKey)
        try store.setData(Data([0xCA, 0xFE]), for: .certificateAuthorityPrivateKey)

        XCTAssertEqual(try store.string(for: .cheapRouterAPIKey), "secret")
        XCTAssertEqual(try store.data(for: .certificateAuthorityPrivateKey), Data([0xCA, 0xFE]))

        try store.delete(.cheapRouterAPIKey)

        XCTAssertNil(try store.string(for: .cheapRouterAPIKey))
        XCTAssertEqual(try store.data(for: .certificateAuthorityPrivateKey), Data([0xCA, 0xFE]))
    }

    func testMigratingKeychainStoreCopiesFallbackSecretToPrimaryAndDeletesFallback() throws {
        let primary = InMemoryKeychainStore()
        let fallback = InMemoryKeychainStore(storage: [.cheapRouterAPIKey: Data("legacy-key".utf8)])
        let store = MigratingKeychainStore(primary: primary, fallback: fallback)

        let migrated = try store.data(for: .cheapRouterAPIKey)

        XCTAssertEqual(migrated, Data("legacy-key".utf8))
        XCTAssertEqual(try primary.data(for: .cheapRouterAPIKey), Data("legacy-key".utf8))
        XCTAssertNil(try fallback.data(for: .cheapRouterAPIKey))
    }

    func testMigratingKeychainStoreDeletesPrimaryAndFallbackSecrets() throws {
        let primary = InMemoryKeychainStore(storage: [.certificateAuthorityMetadata: Data("primary".utf8)])
        let fallback = InMemoryKeychainStore(storage: [.certificateAuthorityMetadata: Data("fallback".utf8)])
        let store = MigratingKeychainStore(primary: primary, fallback: fallback)

        try store.delete(.certificateAuthorityMetadata)

        XCTAssertNil(try primary.data(for: .certificateAuthorityMetadata))
        XCTAssertNil(try fallback.data(for: .certificateAuthorityMetadata))
    }
}
