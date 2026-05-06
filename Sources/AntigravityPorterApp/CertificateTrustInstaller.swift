import Foundation
import Security

struct CertificateTrustInstaller: Sendable {
    private static let certificateLabel = "AntigravityRouter Local CA"

    private let trustManager: any CertificateTrustManaging

    init(trustManager: any CertificateTrustManaging = SecurityCertificateTrustManager()) {
        self.trustManager = trustManager
    }

    func installAndTrust(certificateURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try installAndTrustSynchronously(certificateURL: certificateURL)
        }.value
    }

    private func installAndTrustSynchronously(certificateURL: URL) throws {
        let certificateData = try Data(contentsOf: certificateURL)
        guard let certificate = trustManager.certificate(from: certificateData) else {
            throw CertificateTrustInstallerError.invalidCertificate
        }

        try trustManager.removeExistingCertificates(label: Self.certificateLabel)
        try trustManager.addToLoginKeychain(certificate, label: Self.certificateLabel)
        try trustManager.trustForSSL(certificate)
    }
}

protocol CertificateTrustManaging: Sendable {
    func certificate(from data: Data) -> SecCertificate?
    func removeExistingCertificates(label: String) throws
    func addToLoginKeychain(_ certificate: SecCertificate, label: String) throws
    func trustForSSL(_ certificate: SecCertificate) throws
}

struct SecurityCertificateTrustManager: CertificateTrustManaging {
    func certificate(from data: Data) -> SecCertificate? {
        SecCertificateCreateWithData(nil, data as CFData)
    }

    func removeExistingCertificates(label: String) throws {
        let matchingCertificates = try certificates(label: label)
        for certificate in matchingCertificates {
            let status = SecTrustSettingsRemoveTrustSettings(certificate, SecTrustSettingsDomain.user)
            guard status == errSecSuccess || status == errSecItemNotFound || status == errSecNoTrustSettings else {
                throw CertificateTrustInstallerError.trustSettingsRemoveFailed(status)
            }
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label
        ]
        let status = SecItemDelete(deleteQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CertificateTrustInstallerError.keychainDeleteFailed(status)
        }
    }

    func addToLoginKeychain(_ certificate: SecCertificate, label: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw CertificateTrustInstallerError.keychainAddFailed(status)
        }
    }

    func trustForSSL(_ certificate: SecCertificate) throws {
        let trustSettings: [[String: Any]] = [
            [
                kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
                kSecTrustSettingsResult as String: NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue)
            ]
        ]
        let status = SecTrustSettingsSetTrustSettings(
            certificate,
            SecTrustSettingsDomain.user,
            trustSettings as CFArray
        )
        guard status == errSecSuccess else {
            throw CertificateTrustInstallerError.trustSettingsFailed(status)
        }
    }

    private func certificates(label: String) throws -> [SecCertificate] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            return []
        }
        guard status == errSecSuccess else {
            throw CertificateTrustInstallerError.keychainLookupFailed(status)
        }
        guard let result else {
            return []
        }
        if CFGetTypeID(result) == SecCertificateGetTypeID() {
            return [result as! SecCertificate]
        }
        return result as? [SecCertificate] ?? []
    }
}

enum CertificateTrustInstallerError: Error, LocalizedError, Equatable {
    case invalidCertificate
    case keychainLookupFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case keychainAddFailed(OSStatus)
    case trustSettingsRemoveFailed(OSStatus)
    case trustSettingsFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCertificate:
            return "CA trust install failed: invalid certificate"
        case let .keychainLookupFailed(status):
            return "CA trust install failed: keychain lookup failed \(Self.describe(status))"
        case let .keychainDeleteFailed(status):
            return "CA trust install failed: keychain cleanup failed \(Self.describe(status))"
        case let .keychainAddFailed(status):
            return "CA trust install failed: keychain add failed \(Self.describe(status))"
        case let .trustSettingsRemoveFailed(status):
            return "CA trust install failed: trust cleanup failed \(Self.describe(status))"
        case let .trustSettingsFailed(status):
            return "CA trust install failed: trust settings failed \(Self.describe(status))"
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return message.map { "(\(status)) \($0)" } ?? "(\(status))"
    }
}
