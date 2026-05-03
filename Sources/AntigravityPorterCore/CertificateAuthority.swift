import Foundation
#if canImport(Security)
import Security
#endif

public final class CertificateAuthority {
    public enum Status: Equatable, Sendable {
        case trusted
        case untrusted
        case cleanupPending
        case rotationPending
    }

    public enum LoadAction: Equatable, Sendable {
        case created
        case reused
    }

    public enum LeafPolicy: Equatable, Sendable {
        case allowIntercept
        case excludedHost
    }

    public enum CleanupState: Equatable, Sendable {
        case none
        case staleTrustRemovalRequired
    }

    public enum ManualRemediation: Equatable, Sendable {
        case removeTrustedCertificateInKeychainAccess
    }

    public struct Identity: Codable, Equatable, Sendable {
        public let id: UUID
        public let commonName: String
        public let createdAt: Date
        public let certificateDER: Data
        public let privateKeyAlgorithm: String
        public let keySizeBits: Int
    }

    public struct LoadResult: Equatable, Sendable {
        public let action: LoadAction
        public let identity: Identity
    }

    public struct LeafIdentity: Equatable, Sendable {
        public let hostname: String
        public let authorityID: UUID
        public let generation: Int
        public let certificateDER: Data
        let privateKeyDER: Data
    }

    public struct RotationResult: Equatable, Sendable {
        public let identity: Identity
        public let cleanup: CleanupState
    }

    public struct UninstallResult: Equatable, Sendable {
        public let keychainMaterialRemoved: Bool
        public let manualRemediation: ManualRemediation
    }

    private let keychain: KeychainStoring
    private let keyGenerator: any RSAKeyPairGenerating
    private var currentIdentity: Identity?
    private var leafCache: [String: LeafIdentity] = [:]
    private var leafGeneration = 0

    public private(set) var status: Status = .untrusted

    public init(keychain: KeychainStoring, keyGenerator: any RSAKeyPairGenerating = SecurityRSAKeyPairGenerator()) {
        self.keychain = keychain
        self.keyGenerator = keyGenerator
    }

    public func loadOrCreate() throws -> LoadResult {
        if let currentIdentity {
            return LoadResult(action: .reused, identity: currentIdentity)
        }

        if let data = try keychain.data(for: .certificateAuthorityMetadata),
           let identity = try? JSONDecoder().decode(Identity.self, from: data),
           let privateKeyDER = try keychain.data(for: .certificateAuthorityPrivateKey),
           isUsableIdentity(identity, privateKeyDER: privateKeyDER) {
            currentIdentity = identity
            return LoadResult(action: .reused, identity: identity)
        }

        let identity = try createIdentity()
        currentIdentity = identity
        status = .untrusted

        return LoadResult(action: .created, identity: identity)
    }

    public func leafIdentity(for hostname: String, policy: LeafPolicy) throws -> LeafIdentity {
        guard policy != .excludedHost else {
            throw CertificateAuthorityError.leafGenerationDenied(hostname: hostname)
        }
        guard status != .cleanupPending else {
            throw CertificateAuthorityError.authorityUnavailable(.cleanupPending)
        }

        let cacheKey = hostname.lowercased()
        let identity = try loadOrCreate().identity
        if let cached = leafCache[cacheKey] {
            return cached
        }

        guard let authorityPrivateKeyDER = try keychain.data(for: .certificateAuthorityPrivateKey) else {
            throw CertificateAuthorityError.authorityPrivateKeyMissing
        }

        let leafKeyPair = try keyGenerator.makeKeyPair()
        let certificateDER = try X509CertificateFactory.makeLeafCertificate(
            hostname: hostname,
            authority: identity,
            authorityPrivateKeyDER: authorityPrivateKeyDER,
            leafPublicKeyDER: leafKeyPair.publicKeyDER
        )

        leafGeneration += 1
        let leaf = LeafIdentity(
            hostname: hostname,
            authorityID: identity.id,
            generation: leafGeneration,
            certificateDER: certificateDER,
            privateKeyDER: leafKeyPair.privateKeyDER
        )
        leafCache[cacheKey] = leaf
        return leaf
    }

    public func rotate() throws -> RotationResult {
        leafCache.removeAll()
        leafGeneration = 0

        let identity = try createIdentity()
        currentIdentity = identity
        status = .rotationPending

        return RotationResult(identity: identity, cleanup: .staleTrustRemovalRequired)
    }

    public func uninstall() throws -> UninstallResult {
        try keychain.delete(.certificateAuthorityPrivateKey)
        try keychain.delete(.certificateAuthorityMetadata)
        currentIdentity = nil
        leafCache.removeAll()
        leafGeneration = 0
        status = .cleanupPending

        return UninstallResult(
            keychainMaterialRemoved: true,
            manualRemediation: .removeTrustedCertificateInKeychainAccess
        )
    }

    public func exportSigningIdentityDER() throws -> Data {
        try loadOrCreate().identity.certificateDER
    }

    private func createIdentity() throws -> Identity {
        let keyPair = try keyGenerator.makeKeyPair()
        let id = UUID()
        let createdAt = Date()
        let commonName = "AntigravityPorter Local CA"
        let certificateDER = try X509CertificateFactory.makeSelfSignedCACertificate(
            id: id,
            commonName: commonName,
            createdAt: createdAt,
            publicKeyDER: keyPair.publicKeyDER,
            privateKeyDER: keyPair.privateKeyDER
        )
        let identity = Identity(
            id: id,
            commonName: commonName,
            createdAt: createdAt,
            certificateDER: certificateDER,
            privateKeyAlgorithm: "rsa",
            keySizeBits: keyPair.keySizeBits
        )
        try persist(identity: identity)
        try keychain.setData(keyPair.privateKeyDER, for: .certificateAuthorityPrivateKey)
        return identity
    }

    private func persist(identity: Identity) throws {
        let data = try JSONEncoder().encode(identity)
        try keychain.setData(data, for: .certificateAuthorityMetadata)
    }

    private func isUsableIdentity(_ identity: Identity, privateKeyDER: Data) -> Bool {
        guard !identity.certificateDER.isEmpty, identity.keySizeBits >= 2048 else { return false }
        #if canImport(Security)
        guard SecCertificateCreateWithData(nil, identity.certificateDER as CFData) != nil else { return false }
        return (try? SecurityRSAKeyPairGenerator.privateKey(from: privateKeyDER, keySizeBits: identity.keySizeBits)) != nil
        #else
        return !privateKeyDER.isEmpty
        #endif
    }
}

public enum CertificateAuthorityError: Error, Equatable, Sendable {
    case authorityUnavailable(CertificateAuthority.Status)
    case authorityPrivateKeyMissing
    case cryptographicOperationFailed(String)
    case leafGenerationDenied(hostname: String)
}

public struct RSAKeyPair: Equatable, Sendable {
    public let privateKeyDER: Data
    public let publicKeyDER: Data
    public let keySizeBits: Int
}

public protocol RSAKeyPairGenerating: Sendable {
    func makeKeyPair() throws -> RSAKeyPair
}

public struct SecurityRSAKeyPairGenerator: RSAKeyPairGenerating {
    public init() {}

    public func makeKeyPair() throws -> RSAKeyPair {
        #if canImport(Security)
        let keySizeBits = 2048
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: keySizeBits,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false,
                kSecAttrIsExtractable as String: true
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw CertificateAuthorityError.cryptographicOperationFailed("create-rsa-key: \(Self.errorDescription(error))")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CertificateAuthorityError.cryptographicOperationFailed("copy-public-key")
        }
        return RSAKeyPair(
            privateKeyDER: try Self.externalRepresentation(of: privateKey, operation: "export-private-key"),
            publicKeyDER: try Self.externalRepresentation(of: publicKey, operation: "export-public-key"),
            keySizeBits: keySizeBits
        )
        #else
        throw KeychainStoreError.unsupportedPlatformOperation("Security framework is unavailable")
        #endif
    }

    #if canImport(Security)
    static func privateKey(from privateKeyDER: Data, keySizeBits: Int) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: keySizeBits
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(privateKeyDER as CFData, attributes as CFDictionary, &error) else {
            throw CertificateAuthorityError.cryptographicOperationFailed("import-private-key: \(errorDescription(error))")
        }
        return key
    }

    static func sign(_ data: Data, privateKeyDER: Data, keySizeBits: Int) throws -> Data {
        let privateKey = try privateKey(from: privateKeyDER, keySizeBits: keySizeBits)
        let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
            throw CertificateAuthorityError.cryptographicOperationFailed("signing-algorithm-unsupported")
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, data as CFData, &error) else {
            throw CertificateAuthorityError.cryptographicOperationFailed("sign-certificate: \(errorDescription(error))")
        }
        return signature as Data
    }

    private static func externalRepresentation(of key: SecKey, operation: String) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) else {
            throw CertificateAuthorityError.cryptographicOperationFailed("\(operation): \(errorDescription(error))")
        }
        return data as Data
    }

    private static func errorDescription(_ unmanaged: Unmanaged<CFError>?) -> String {
        guard let unmanaged else { return "unknown-error" }
        return String(describing: unmanaged.takeRetainedValue())
    }
    #endif
}

enum X509CertificateFactory {
    private static let sha256WithRSAEncryption = DER.sequence([
        DER.oid([1, 2, 840, 113549, 1, 1, 11]),
        DER.null()
    ])
    private static let rsaEncryption = DER.sequence([
        DER.oid([1, 2, 840, 113549, 1, 1, 1]),
        DER.null()
    ])

    static func makeSelfSignedCACertificate(
        id: UUID,
        commonName: String,
        createdAt: Date,
        publicKeyDER: Data,
        privateKeyDER: Data
    ) throws -> Data {
        let name = distinguishedName(commonName: commonName)
        let validity = DER.sequence([
            DER.utcTime(createdAt.addingTimeInterval(-300)),
            DER.utcTime(createdAt.addingTimeInterval(10 * 365 * 24 * 60 * 60))
        ])
        let extensions = DER.explicit(tag: 3, DER.sequence([
            x509Extension(oid: [2, 5, 29, 19], critical: true, value: DER.sequence([DER.boolean(true)])),
            x509Extension(oid: [2, 5, 29, 15], critical: true, value: DER.bitString(Data([0x06]), unusedBits: 1))
        ]))
        let tbsCertificate = DER.sequence([
            DER.explicit(tag: 0, DER.integer(2)),
            DER.integer(serialBytes(seed: id.uuidString)),
            sha256WithRSAEncryption,
            name,
            validity,
            name,
            subjectPublicKeyInfo(publicKeyDER: publicKeyDER),
            extensions
        ])
        let signature = try SecurityRSAKeyPairGenerator.sign(tbsCertificate, privateKeyDER: privateKeyDER, keySizeBits: 2048)
        return DER.sequence([
            tbsCertificate,
            sha256WithRSAEncryption,
            DER.bitString(signature)
        ])
    }

    static func makeLeafCertificate(
        hostname: String,
        authority: CertificateAuthority.Identity,
        authorityPrivateKeyDER: Data,
        leafPublicKeyDER: Data
    ) throws -> Data {
        let now = Date()
        let issuer = distinguishedName(commonName: authority.commonName)
        let subject = distinguishedName(commonName: hostname)
        let validity = DER.sequence([
            DER.utcTime(now.addingTimeInterval(-300)),
            DER.utcTime(now.addingTimeInterval(365 * 24 * 60 * 60))
        ])
        let extensions = DER.explicit(tag: 3, DER.sequence([
            x509Extension(oid: [2, 5, 29, 19], critical: true, value: DER.sequence([])),
            x509Extension(oid: [2, 5, 29, 15], critical: true, value: DER.bitString(Data([0xA0]), unusedBits: 5)),
            x509Extension(oid: [2, 5, 29, 37], critical: false, value: DER.sequence([DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1])])),
            x509Extension(oid: [2, 5, 29, 17], critical: false, value: DER.sequence([DER.contextSpecificPrimitive(tag: 2, Data(hostname.utf8))]))
        ]))
        let tbsCertificate = DER.sequence([
            DER.explicit(tag: 0, DER.integer(2)),
            DER.integer(serialBytes(seed: hostname + authority.id.uuidString)),
            sha256WithRSAEncryption,
            issuer,
            validity,
            subject,
            subjectPublicKeyInfo(publicKeyDER: leafPublicKeyDER),
            extensions
        ])
        let signature = try SecurityRSAKeyPairGenerator.sign(tbsCertificate, privateKeyDER: authorityPrivateKeyDER, keySizeBits: authority.keySizeBits)
        return DER.sequence([
            tbsCertificate,
            sha256WithRSAEncryption,
            DER.bitString(signature)
        ])
    }

    private static func subjectPublicKeyInfo(publicKeyDER: Data) -> Data {
        DER.sequence([
            rsaEncryption,
            DER.bitString(publicKeyDER)
        ])
    }

    private static func distinguishedName(commonName: String) -> Data {
        DER.sequence([
            DER.set([
                DER.sequence([
                    DER.oid([2, 5, 4, 3]),
                    DER.utf8String(commonName)
                ])
            ])
        ])
    }

    private static func x509Extension(oid: [Int], critical: Bool, value: Data) -> Data {
        var elements = [DER.oid(oid)]
        if critical {
            elements.append(DER.boolean(true))
        }
        elements.append(DER.octetString(value))
        return DER.sequence(elements)
    }

    private static func serialBytes(seed: String) -> Data {
        var bytes = Array(seed.utf8.prefix(16))
        if bytes.count < 16 {
            bytes.append(contentsOf: repeatElement(0x5A, count: 16 - bytes.count))
        }
        bytes[0] &= 0x7F
        return Data(bytes)
    }
}

enum DER {
    static func sequence(_ values: [Data]) -> Data {
        tagged(0x30, concatenate(values))
    }

    static func set(_ values: [Data]) -> Data {
        tagged(0x31, concatenate(values))
    }

    static func explicit(tag: UInt8, _ value: Data) -> Data {
        tagged(0xA0 | tag, value)
    }

    static func contextSpecificPrimitive(tag: UInt8, _ value: Data) -> Data {
        tagged(0x80 | tag, value)
    }

    static func integer(_ value: Int) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        return integer(Data(bytes))
    }

    static func integer(_ bytes: Data) -> Data {
        var normalized = Array(bytes.drop { $0 == 0 })
        if normalized.isEmpty {
            normalized = [0]
        }
        if let first = normalized.first, first & 0x80 != 0 {
            normalized.insert(0, at: 0)
        }
        return tagged(0x02, Data(normalized))
    }

    static func oid(_ components: [Int]) -> Data {
        precondition(components.count >= 2)
        var body = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            body.append(contentsOf: base128(component))
        }
        return tagged(0x06, body)
    }

    static func null() -> Data {
        Data([0x05, 0x00])
    }

    static func boolean(_ value: Bool) -> Data {
        tagged(0x01, Data([value ? 0xFF : 0x00]))
    }

    static func bitString(_ data: Data, unusedBits: UInt8 = 0) -> Data {
        tagged(0x03, Data([unusedBits]) + data)
    }

    static func octetString(_ data: Data) -> Data {
        tagged(0x04, data)
    }

    static func utf8String(_ string: String) -> Data {
        tagged(0x0C, Data(string.utf8))
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(0x17, Data(formatter.string(from: date).utf8))
    }

    private static func tagged(_ tag: UInt8, _ body: Data) -> Data {
        Data([tag]) + length(body.count) + body
    }

    private static func concatenate(_ values: [Data]) -> Data {
        values.reduce(into: Data()) { result, value in
            result.append(value)
        }
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 {
            return Data([UInt8(count)])
        }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func base128(_ value: Int) -> [UInt8] {
        var chunks = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            chunks.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return chunks
    }
}
