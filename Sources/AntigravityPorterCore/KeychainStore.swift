import Foundation

public enum KeychainSecretKey: String, CaseIterable, CustomStringConvertible, Sendable {
    case cheapRouterAPIKey
    case certificateAuthorityPrivateKey
    case certificateAuthorityMetadata

    public var description: String {
        rawValue
    }
}

public enum KeychainStoreError: Error, Equatable, Sendable {
    case unsupportedPlatformOperation(String)
    case invalidStringData(KeychainSecretKey)
}

public protocol KeychainStoring {
    func data(for key: KeychainSecretKey) throws -> Data?
    func setData(_ data: Data, for key: KeychainSecretKey) throws
    func delete(_ key: KeychainSecretKey) throws
}

public extension KeychainStoring {
    func string(for key: KeychainSecretKey) throws -> String? {
        guard let data = try data(for: key) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidStringData(key)
        }
        return string
    }

    func setString(_ string: String, for key: KeychainSecretKey) throws {
        try setData(Data(string.utf8), for: key)
    }
}

public final class InMemoryKeychainStore: KeychainStoring, CustomStringConvertible {
    private var storage: [KeychainSecretKey: Data]

    public init(storage: [KeychainSecretKey: Data] = [:]) {
        self.storage = storage
    }

    public var description: String {
        "InMemoryKeychainStore(keys: \(storage.keys.map(\.rawValue).sorted()))"
    }

    public func data(for key: KeychainSecretKey) throws -> Data? {
        storage[key]
    }

    public func setData(_ data: Data, for key: KeychainSecretKey) throws {
        storage[key] = data
    }

    public func delete(_ key: KeychainSecretKey) throws {
        storage.removeValue(forKey: key)
    }
}

public struct SecurityKeychainStore: KeychainStoring {
    private static let unsupportedMessage = "SecurityKeychainStore is not implemented yet"

    public init() {}

    public func data(for key: KeychainSecretKey) throws -> Data? {
        throw KeychainStoreError.unsupportedPlatformOperation(Self.unsupportedMessage)
    }

    public func setData(_ data: Data, for key: KeychainSecretKey) throws {
        throw KeychainStoreError.unsupportedPlatformOperation(Self.unsupportedMessage)
    }

    public func delete(_ key: KeychainSecretKey) throws {
        throw KeychainStoreError.unsupportedPlatformOperation(Self.unsupportedMessage)
    }
}
