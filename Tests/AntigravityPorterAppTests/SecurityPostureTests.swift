import Foundation
import XCTest
@testable import AntigravityPorterApp

final class SecurityPostureTests: XCTestCase {
    func testLogTruncationCreatesPrivateLogFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRouterLogs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = PorterRuntimeController(logDirectory: directory)

        runtime.truncateLogs()

        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(directoryMode, 0o700)
        for name in ["runtime.log", "raw-http.log"] {
            let file = directory.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber).intValue & 0o777
            XCTAssertEqual(mode, 0o600, name)
        }
    }

    func testSourceKeepsAntigravityModelDiscoveryOutOfProviderRouting() throws {
        let root = packageRoot()
        let nwProxyServer = try String(contentsOf: root.appendingPathComponent("Sources/AntigravityPorterApp/NWProxyServer.swift"))
        let translators = try String(contentsOf: root.appendingPathComponent("Sources/AntigravityPorterCore/Translators.swift"))

        XCTAssertFalse(nwProxyServer.contains("routeProviderModelsForAntigravity"))
        XCTAssertFalse(translators.contains("AntigravityModelsResponseBuilder"))
    }

    func testSourceBindsEphemeralTLSTerminationToLoopback() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/NWProxyServer.swift"))

        XCTAssertTrue(source.contains("requiredLocalEndpoint"))
        XCTAssertTrue(source.contains(#"host: "127.0.0.1""#))
    }

    func testSourceHasNoUnusedTrustBypassDelegate() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/PorterRuntimeController.swift"))

        XCTAssertFalse(source.contains("GoogleUpstreamSessionDelegate"))
        XCTAssertFalse(source.contains("URLCredential(trust: trust)"))
    }

    func testSourceUsesSecurityKeychainPrimaryForCAMaterial() throws {
        let appSource = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))
        let runtimeSource = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/PorterRuntimeController.swift"))

        XCTAssertTrue(appSource.contains("SecurityKeychainStore(service: \"uk.cheaprouter.AntigravityPorter.ca\")"))
        XCTAssertTrue(runtimeSource.contains("SecurityKeychainStore(service: \"uk.cheaprouter.AntigravityPorter.ca\")"))
        XCTAssertTrue(appSource.contains("MigratingKeychainStore"))
        XCTAssertTrue(runtimeSource.contains("MigratingKeychainStore"))
    }

    func testSourceHasNoPerModelRoutingState() throws {
        let root = packageRoot()
        let sourceFiles = [
            root.appendingPathComponent("Sources/AntigravityPorterApp/NWProxyServer.swift"),
            root.appendingPathComponent("Sources/AntigravityPorterCore/SettingsStore.swift"),
            root.appendingPathComponent("Sources/AntigravityPorterCore/Translators.swift")
        ]
        let source = try sourceFiles.map { try String(contentsOf: $0) }.joined(separator: "\n")

        XCTAssertFalse(source.contains("routedModels"))
        XCTAssertFalse(source.contains("routesViaCheapRouter"))
        XCTAssertFalse(source.contains("setRouteViaCheapRouter"))
    }

    func testCAInstallButtonInstallsTrustInsteadOfOpeningCertificate() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))

        XCTAssertTrue(source.contains(#"Button("Install CA""#))
        XCTAssertTrue(source.contains("Install and trust the CA certificate for this user"))
        XCTAssertTrue(source.contains("Requesting trust approval..."))
        XCTAssertFalse(source.contains(#"Button("Export/Open""#))
        XCTAssertFalse(source.contains("NSWorkspace.shared.open(certificateURL)"))
        let installCertificateRange = try XCTUnwrap(source.range(of: "private func installCertificate()"))
        let writeCertificateRange = try XCTUnwrap(source.range(of: "private func writeCertificateForTrustSetup"))
        let installCertificateBody = String(source[installCertificateRange.lowerBound..<writeCertificateRange.lowerBound])
        XCTAssertFalse(installCertificateBody.contains("Task.detached"))
    }

    func testCertificateTrustInstallerUsesNativeUserTrustSettings() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/CertificateTrustInstaller.swift"))

        XCTAssertTrue(source.contains("protocol CertificateTrustManaging"))
        XCTAssertTrue(source.contains("removeExistingCertificates"))
        XCTAssertTrue(source.contains("SecTrustSettingsSetTrustSettings"))
        XCTAssertTrue(source.contains("SecTrustSettingsDomain.user"))
        XCTAssertTrue(source.contains("SecPolicyCreateSSL(true, nil)"))
        XCTAssertTrue(source.contains("SecTrustSettingsResult.trustRoot"))
        XCTAssertFalse(source.contains("SecTrustSettingsDomain.user,\n            nil"))
        XCTAssertFalse(source.contains("/usr/bin/osascript"))
        XCTAssertFalse(source.contains("with administrator privileges"))
        XCTAssertFalse(source.contains("System.keychain"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
