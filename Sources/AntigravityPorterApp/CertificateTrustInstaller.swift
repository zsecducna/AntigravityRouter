import Foundation

struct CertificateTrustInstaller: Sendable {
    func installAndTrust(certificateURL: URL) throws {
        try runPrivilegedShell(Self.installScript(certificateURL: certificateURL))
    }

    static func installScript(certificateURL: URL) -> String {
        let certPath = shellQuote(certificateURL.path)
        return """
        set -e
        cert_path=\(certPath)
        system_keychain="/Library/Keychains/System.keychain"
        fingerprint="$(/usr/bin/openssl x509 -inform DER -in "$cert_path" -noout -fingerprint -sha1 | /usr/bin/sed 's/^.*=//;s/://g')"
        if [ -n "$fingerprint" ]; then
          /usr/bin/security delete-certificate -Z "$fingerprint" "$system_keychain" >/dev/null 2>&1 || true
        fi
        /usr/bin/security add-trusted-cert -d -r trustRoot -k "$system_keychain" "$cert_path"
        """
    }

    private func runPrivilegedShell(_ shellScript: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \(Self.appleScriptString(shellScript)) with administrator privileges"
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CertificateTrustInstallerError.commandFailed(
                status: process.terminationStatus,
                output: output,
                error: error
            )
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        + "\""
    }
}

enum CertificateTrustInstallerError: Error, LocalizedError, Equatable {
    case commandFailed(status: Int32, output: String, error: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(status, output, error):
            let detail = error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? output.trimmingCharacters(in: .whitespacesAndNewlines)
                : error.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "CA trust install failed (\(status))"
            }
            return "CA trust install failed (\(status)): \(detail)"
        }
    }
}
