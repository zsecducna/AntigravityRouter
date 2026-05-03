import Foundation

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
    }

    public struct LoadResult: Equatable, Sendable {
        public let action: LoadAction
        public let identity: Identity
    }

    public struct LeafIdentity: Equatable, Sendable {
        public let hostname: String
        public let authorityID: UUID
        public let generation: Int
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
    private var currentIdentity: Identity?
    private var leafCache: [String: LeafIdentity] = [:]
    private var leafGeneration = 0

    public private(set) var status: Status = .untrusted

    public init(keychain: KeychainStoring) {
        self.keychain = keychain
    }

    public func loadOrCreate() throws -> LoadResult {
        if let currentIdentity {
            return LoadResult(action: .reused, identity: currentIdentity)
        }

        if let data = try keychain.data(for: .certificateAuthorityMetadata),
           let identity = try? JSONDecoder().decode(Identity.self, from: data) {
            currentIdentity = identity
            return LoadResult(action: .reused, identity: identity)
        }

        let identity = Identity(
            id: UUID(),
            commonName: "AntigravityPorter Local CA",
            createdAt: Date()
        )
        try persist(identity: identity)
        try keychain.setData(Data("placeholder-private-key-\(identity.id.uuidString)".utf8), for: .certificateAuthorityPrivateKey)
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

        let identity = try loadOrCreate().identity
        if let cached = leafCache[hostname] {
            return cached
        }

        leafGeneration += 1
        let leaf = LeafIdentity(hostname: hostname, authorityID: identity.id, generation: leafGeneration)
        leafCache[hostname] = leaf
        return leaf
    }

    public func rotate() throws -> RotationResult {
        leafCache.removeAll()
        leafGeneration = 0

        let identity = Identity(
            id: UUID(),
            commonName: "AntigravityPorter Local CA",
            createdAt: Date()
        )
        try persist(identity: identity)
        try keychain.setData(Data("placeholder-private-key-\(identity.id.uuidString)".utf8), for: .certificateAuthorityPrivateKey)
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
        throw CertificateAuthorityError.cryptographicSigningUnsupported
    }

    private func persist(identity: Identity) throws {
        let data = try JSONEncoder().encode(identity)
        try keychain.setData(data, for: .certificateAuthorityMetadata)
    }
}

public enum CertificateAuthorityError: Error, Equatable, Sendable {
    case authorityUnavailable(CertificateAuthority.Status)
    case cryptographicSigningUnsupported
    case leafGenerationDenied(hostname: String)
}
