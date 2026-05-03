import XCTest
@testable import AntigravityPorterCore

final class CertificateAuthorityTests: XCTestCase {
    func testCAIdentityCreatedOnceAndReusedFromKeychain() throws {
        let store = InMemoryKeychainStore()
        let authority = CertificateAuthority(keychain: store)

        let created = try authority.loadOrCreate()
        let reused = try authority.loadOrCreate()

        XCTAssertEqual(created.action, .created)
        XCTAssertEqual(reused.action, .reused)
        XCTAssertEqual(created.identity.id, reused.identity.id)
        XCTAssertEqual(authority.status, .untrusted)
    }

    func testLeafCacheIsKeyedByHostnameAndInvalidatedOnRotation() throws {
        let authority = CertificateAuthority(keychain: InMemoryKeychainStore())
        _ = try authority.loadOrCreate()

        let first = try authority.leafIdentity(for: "generativelanguage.googleapis.com", policy: .allowIntercept)
        let cached = try authority.leafIdentity(for: "generativelanguage.googleapis.com", policy: .allowIntercept)
        let other = try authority.leafIdentity(for: "cloudcode-pa.googleapis.com", policy: .allowIntercept)

        XCTAssertEqual(first, cached)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.hostname, "generativelanguage.googleapis.com")

        let rotation = try authority.rotate()
        let afterRotation = try authority.leafIdentity(for: "generativelanguage.googleapis.com", policy: .allowIntercept)

        XCTAssertEqual(rotation.cleanup, .staleTrustRemovalRequired)
        XCTAssertEqual(authority.status, .rotationPending)
        XCTAssertNotEqual(first, afterRotation)
    }

    func testUninstallClearsOwnedMaterialAndBlocksStaleLeafReuse() throws {
        let store = InMemoryKeychainStore()
        let authority = CertificateAuthority(keychain: store)
        _ = try authority.loadOrCreate()
        _ = try authority.leafIdentity(for: "generativelanguage.googleapis.com", policy: .allowIntercept)

        let result = try authority.uninstall()

        XCTAssertEqual(result.keychainMaterialRemoved, true)
        XCTAssertEqual(result.manualRemediation, .removeTrustedCertificateInKeychainAccess)
        XCTAssertEqual(authority.status, .cleanupPending)
        XCTAssertNil(try store.data(for: .certificateAuthorityPrivateKey))
        XCTAssertThrowsError(try authority.leafIdentity(for: "generativelanguage.googleapis.com", policy: .allowIntercept)) { error in
            XCTAssertEqual(error as? CertificateAuthorityError, .authorityUnavailable(.cleanupPending))
        }
    }

    func testExcludedHostsNeverReceiveLeafIdentities() throws {
        let authority = CertificateAuthority(keychain: InMemoryKeychainStore())
        _ = try authority.loadOrCreate()

        XCTAssertThrowsError(try authority.leafIdentity(for: "oauth2.googleapis.com", policy: .excludedHost)) { error in
            XCTAssertEqual(error as? CertificateAuthorityError, .leafGenerationDenied(hostname: "oauth2.googleapis.com"))
        }
    }

    func testRealCryptographicSigningSurfaceIsExplicitlyUnsupported() throws {
        let authority = CertificateAuthority(keychain: InMemoryKeychainStore())
        _ = try authority.loadOrCreate()

        XCTAssertThrowsError(try authority.exportSigningIdentityDER()) { error in
            XCTAssertEqual(error as? CertificateAuthorityError, .cryptographicSigningUnsupported)
        }
    }
}
