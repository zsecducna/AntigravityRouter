import XCTest
@testable import AntigravityPorterCore

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

    func testSecurityBackedStoreIsExplicitlyUnsupportedPlaceholder() {
        let store = SecurityKeychainStore()

        XCTAssertThrowsError(try store.setString("secret", for: .cheapRouterAPIKey)) { error in
            XCTAssertEqual(error as? KeychainStoreError, .unsupportedPlatformOperation("SecurityKeychainStore is not implemented yet"))
        }
    }
}
