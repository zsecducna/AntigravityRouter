import XCTest
@testable import AntigravityPorterCore
#if canImport(Security)
import Security
#endif

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
        XCTAssertEqual(created.identity.privateKeyAlgorithm, "rsa")
        XCTAssertEqual(created.identity.keySizeBits, 2048)
        XCTAssertFalse(created.identity.certificateDER.isEmpty)
        XCTAssertFalse(try XCTUnwrap(store.data(for: .certificateAuthorityPrivateKey)).isEmpty)
        #if canImport(Security)
        XCTAssertNotNil(SecCertificateCreateWithData(nil, created.identity.certificateDER as CFData))
        #endif
    }

    func testLeafCacheIsKeyedByHostnameAndInvalidatedOnRotation() throws {
        let authority = CertificateAuthority(keychain: InMemoryKeychainStore())
        _ = try authority.loadOrCreate()

        let first = try authority.leafIdentity(for: "cloudcode-pa.googleapis.com", policy: .allowIntercept)
        let cached = try authority.leafIdentity(for: "cloudcode-pa.googleapis.com", policy: .allowIntercept)
        let other = try authority.leafIdentity(for: "daily-cloudcode-pa.googleapis.com", policy: .allowIntercept)

        XCTAssertEqual(first, cached)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.hostname, "cloudcode-pa.googleapis.com")
        XCTAssertFalse(first.certificateDER.isEmpty)
        XCTAssertFalse(first.privateKeyDER.isEmpty)
        XCTAssertTrue(String(decoding: first.certificateDER, as: UTF8.self).contains("cloudcode-pa.googleapis.com"))
        #if canImport(Security)
        XCTAssertNotNil(SecCertificateCreateWithData(nil, first.certificateDER as CFData))
        #endif

        let rotation = try authority.rotate()
        let afterRotation = try authority.leafIdentity(for: "cloudcode-pa.googleapis.com", policy: .allowIntercept)

        XCTAssertEqual(rotation.cleanup, .staleTrustRemovalRequired)
        XCTAssertEqual(authority.status, .rotationPending)
        XCTAssertNotEqual(first, afterRotation)
    }

    func testUninstallClearsOwnedMaterialAndBlocksStaleLeafReuse() throws {
        let store = InMemoryKeychainStore()
        let authority = CertificateAuthority(keychain: store)
        _ = try authority.loadOrCreate()
        _ = try authority.leafIdentity(for: "cloudcode-pa.googleapis.com", policy: .allowIntercept)

        let result = try authority.uninstall()

        XCTAssertEqual(result.keychainMaterialRemoved, true)
        XCTAssertEqual(result.manualRemediation, .removeTrustedCertificateInKeychainAccess)
        XCTAssertEqual(authority.status, .cleanupPending)
        XCTAssertNil(try store.data(for: .certificateAuthorityPrivateKey))
        XCTAssertThrowsError(try authority.leafIdentity(for: "cloudcode-pa.googleapis.com", policy: .allowIntercept)) { error in
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

    func testExportReturnsParseableCACertificateDER() throws {
        let authority = CertificateAuthority(keychain: InMemoryKeychainStore())
        let created = try authority.loadOrCreate()

        let exported = try authority.exportSigningIdentityDER()

        XCTAssertEqual(exported, created.identity.certificateDER)
        #if canImport(Security)
        XCTAssertNotNil(SecCertificateCreateWithData(nil, exported as CFData))
        #endif
    }
}
