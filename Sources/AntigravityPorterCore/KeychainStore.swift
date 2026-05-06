import Foundation
#if canImport(Security)
import Security
#endif

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
    case securityFrameworkError(operation: String, key: KeychainSecretKey, status: Int32)
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

public final class MigratingKeychainStore: KeychainStoring, @unchecked Sendable {
    private let primary: any KeychainStoring
    private let fallback: any KeychainStoring

    public init(primary: any KeychainStoring, fallback: any KeychainStoring) {
        self.primary = primary
        self.fallback = fallback
    }

    public func data(for key: KeychainSecretKey) throws -> Data? {
        if let data = try primary.data(for: key) {
            return data
        }
        guard let legacy = try fallback.data(for: key) else {
            return nil
        }
        try primary.setData(legacy, for: key)
        try fallback.delete(key)
        return legacy
    }

    public func setData(_ data: Data, for key: KeychainSecretKey) throws {
        try primary.setData(data, for: key)
        try? fallback.delete(key)
    }

    public func delete(_ key: KeychainSecretKey) throws {
        var firstError: Error?
        do {
            try primary.delete(key)
        } catch {
            firstError = error
        }
        do {
            try fallback.delete(key)
        } catch where firstError == nil {
            firstError = error
        }
        if let firstError {
            throw firstError
        }
    }
}

public struct SecurityKeychainStore: KeychainStoring, Sendable {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "uk.cheaprouter.AntigravityPorter", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func data(for key: KeychainSecretKey) throws -> Data? {
        #if canImport(Security)
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.securityFrameworkError(operation: "read", key: key, status: status)
        }
        return result as? Data
        #else
        throw KeychainStoreError.unsupportedPlatformOperation("Security framework is unavailable")
        #endif
    }

    public func setData(_ data: Data, for key: KeychainSecretKey) throws {
        #if canImport(Security)
        var addQuery = baseQuery(for: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(for: key) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.securityFrameworkError(operation: "update", key: key, status: updateStatus)
            }
            return
        }
        throw KeychainStoreError.securityFrameworkError(operation: "write", key: key, status: addStatus)
        #else
        throw KeychainStoreError.unsupportedPlatformOperation("Security framework is unavailable")
        #endif
    }

    public func delete(_ key: KeychainSecretKey) throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.securityFrameworkError(operation: "delete", key: key, status: status)
        }
        #else
        throw KeychainStoreError.unsupportedPlatformOperation("Security framework is unavailable")
        #endif
    }

    #if canImport(Security)
    private func baseQuery(for key: KeychainSecretKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
    #endif
}
