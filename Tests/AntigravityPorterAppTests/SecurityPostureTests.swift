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

        XCTAssertFalse(source.contains("var routedModels"))
        XCTAssertFalse(source.contains("let routedModels"))
        XCTAssertFalse(source.contains("case routedModels ="))
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

    func testStatusTabUsesCurrentLabelsAndVisibleUpdateStatus() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))

        XCTAssertTrue(source.contains(#"statusRow("MITM", runtime.status.proxyEnabled ? "On" : "Off")"#))
        XCTAssertTrue(source.contains("runtime.status.providerReachability.displayText"))
        XCTAssertTrue(source.contains("Text(updater.statusMessage)"))
        XCTAssertFalse(source.contains(#"statusRow("Mode", runtime.status.proxyEnabled ? "listening" : "off")"#))
    }

    func testGoogleStartupRequestsDoNotCountAsDirectModelRequests() throws {
        let root = packageRoot()
        let runtimeSource = try String(contentsOf: root.appendingPathComponent("Sources/AntigravityPorterApp/PorterRuntimeController.swift"))
        let proxySource = try String(contentsOf: root.appendingPathComponent("Sources/AntigravityPorterApp/NWProxyServer.swift"))

        XCTAssertTrue(runtimeSource.contains("case let .directModel(line):"))
        XCTAssertTrue(runtimeSource.contains("status.googleDirectRequests += 1"))
        XCTAssertTrue(runtimeSource.contains("case let .direct(line):\n            appendRuntimeLog(line)"))
        XCTAssertTrue(proxySource.contains(".directModel(\"Google direct model="))
        XCTAssertTrue(proxySource.contains(#".direct("\(source) \(routingHost)\(request.path) status=\(response.statusCode)")"#))
    }

    func testStatusTabFitsInMenuBarWindow() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))

        XCTAssertTrue(source.contains("private static let mainWindowWidth: CGFloat = 560"))
        XCTAssertTrue(source.contains("private static let mainWindowHeight: CGFloat = 660"))
        XCTAssertTrue(source.contains("width: setupWizardCompleted ? Self.mainWindowWidth : Self.setupWizardWindowWidth"))
        XCTAssertTrue(source.contains("height: setupWizardCompleted ? Self.mainWindowHeight : Self.setupWizardWindowHeight"))
        XCTAssertTrue(source.contains("ScrollView {"))
        XCTAssertTrue(source.contains("statusContent"))
    }

    func testSettingsTabAllowsTypedProxyPortInput() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))

        XCTAssertTrue(source.contains(#"TextField("8877", text: $proxyPortText)"#))
        XCTAssertTrue(source.contains("normalizeProxyPortText"))
        XCTAssertTrue(source.contains("commitProxyPortText"))
        XCTAssertTrue(source.contains("min(max(port, 1024), 65535)"))
    }

    func testUnsafeFullBodyLogConfirmationUsesClickableInlineControls() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))

        XCTAssertTrue(source.contains("unsafeFullBodyLogConfirmation"))
        XCTAssertTrue(source.contains(#"Button("Enable", systemImage: "exclamationmark.triangle")"#))
        XCTAssertTrue(source.contains(#"Button("Cancel", systemImage: "xmark")"#))
        XCTAssertFalse(source.contains(#".alert("Enable unsafe full body log?""#))
    }

    func testFirstRunSetupWizardGuidesInstallAndLaunch() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))

        XCTAssertTrue(source.contains(#"private static let setupWizardCompletedKey = "AntigravityRouter.setupWizardCompleted.v1""#))
        XCTAssertTrue(source.contains("if setupWizardCompleted"))
        XCTAssertTrue(source.contains("setupWizard"))
        XCTAssertTrue(source.contains("SetupWizardStep.welcome"))
        XCTAssertTrue(source.contains("case welcome"))
        XCTAssertTrue(source.contains("case certificate"))
        XCTAssertTrue(source.contains("case provider"))
        XCTAssertTrue(source.contains("case check"))
        XCTAssertTrue(source.contains("case finish"))
        XCTAssertTrue(source.contains(#"Button("Install CA", systemImage: "key")"#))
        XCTAssertTrue(source.contains(#"Button("Check API Key and Fetch Models", systemImage: "checkmark.seal")"#))
        XCTAssertTrue(source.contains(#"Button("Finish and Relaunch Antigravity", systemImage: "arrow.clockwise")"#))
        XCTAssertTrue(source.contains("providerModelsCheckSucceeded"))
        XCTAssertTrue(source.contains("certificateInstallSucceeded"))
        XCTAssertTrue(source.contains(".disabled(!certificateInstallSucceeded)"))
        XCTAssertTrue(source.contains("updated.customProviderRoutingEnabled = true"))
        XCTAssertTrue(source.contains("try settingsStore.save(updated)"))
        XCTAssertTrue(source.contains("launchAntigravityViaPorter(completeSetupOnSuccess: true)"))
        XCTAssertTrue(source.contains("setupWizardCompleted = true"))
        XCTAssertTrue(source.contains(#"Button("Open Setup", systemImage: "list.bullet.clipboard")"#))
    }

    func testSetupFinishPersistsRoutingBeforeLaunch() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))
        let finishRange = try XCTUnwrap(source.range(of: "private func finishSetupAndLaunchAntigravity()"))
        let nextFunctionRange = try XCTUnwrap(source.range(of: "private func quitAndRelaunchAntigravityWithoutProxy()"))
        let finishBody = String(source[finishRange.lowerBound..<nextFunctionRange.lowerBound])

        XCTAssertTrue(finishBody.contains("updated.customProviderRoutingEnabled = true"))
        let saveRange = try XCTUnwrap(finishBody.range(of: "try settingsStore.save(updated)"))
        let assignRange = try XCTUnwrap(finishBody.range(of: "settings = updated"))
        let launchRange = try XCTUnwrap(finishBody.range(of: "launchAntigravityViaPorter(completeSetupOnSuccess: true)"))
        XCTAssertLessThan(saveRange.lowerBound, assignRange.lowerBound)
        XCTAssertLessThan(assignRange.lowerBound, launchRange.lowerBound)
    }

    func testSetupWizardInvalidatesProviderCheckWhenInputsChange() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))

        XCTAssertTrue(source.contains(".onChange(of: baseURLText)"))
        XCTAssertTrue(source.contains(".onChange(of: apiKey)"))
        XCTAssertTrue(source.contains("invalidateProviderModelsCheck()"))

        let invalidateRange = try XCTUnwrap(source.range(of: "private func invalidateProviderModelsCheck()"))
        let nextFunctionRange = try XCTUnwrap(source.range(of: "private func saveProviderConfiguration()"))
        let invalidateBody = String(source[invalidateRange.lowerBound..<nextFunctionRange.lowerBound])
        XCTAssertTrue(invalidateBody.contains("providerModelsCheckSucceeded = false"))
        XCTAssertTrue(invalidateBody.contains("providerModels = []"))
        XCTAssertTrue(invalidateBody.contains(#"modelsMessage = "Not checked""#))
    }

    func testProviderURLFieldCommitsBeforeStatusAndModelRefreshUseIt() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))

        XCTAssertTrue(source.contains(".onChange(of: selectedTab)"))
        XCTAssertTrue(source.contains("commitProviderBaseURLIfValid()"))
        XCTAssertFalse(source.contains(#"Text("cheaprouter.uk")"#))

        let refreshRange = try XCTUnwrap(source.range(of: "private func refreshProviderModels()"))
        let nextFunctionRange = try XCTUnwrap(source.range(of: "private func installCertificate()"))
        let refreshBody = String(source[refreshRange.lowerBound..<nextFunctionRange.lowerBound])
        XCTAssertTrue(refreshBody.contains("guard commitProviderBaseURL() else { return }"))
        XCTAssertTrue(refreshBody.contains("settings.cheapRouterBaseURL"))
    }

    func testProviderURLValidationAllowsHTTPAndHTTPS() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))

        XCTAssertTrue(source.contains("isSupportedProviderURLScheme"))
        XCTAssertTrue(source.contains(#"scheme == "http" || scheme == "https""#))
        XCTAssertTrue(source.contains("Provider URL must use HTTP or HTTPS"))
        XCTAssertFalse(source.contains(#"url.scheme == "https""#))
        XCTAssertFalse(source.contains("Provider URL must be HTTPS"))
    }

    func testQuitConfirmsAndRelaunchesAntigravityWithoutProxy() throws {
        let source = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))

        XCTAssertTrue(source.contains("quitConfirmationPending = true"))
        XCTAssertTrue(source.contains("private var quitConfirmation: some View"))
        XCTAssertTrue(source.contains(#"Text("Quit AntigravityRouter?")"#))
        XCTAssertTrue(source.contains(#"Button("Quit and Relaunch Antigravity", systemImage: "power")"#))
        XCTAssertTrue(source.contains(#"Button("Cancel", systemImage: "xmark")"#))
        XCTAssertFalse(source.contains(#".alert("Quit AntigravityRouter?""#))
        XCTAssertTrue(source.contains("quitAndRelaunchAntigravityWithoutProxy"))
        XCTAssertTrue(source.contains("environmentWithoutProxy"))
        XCTAssertTrue(source.contains(#""HTTP_PROXY""#))
        XCTAssertTrue(source.contains(#""NODE_EXTRA_CA_CERTS""#))

        let quitRange = try XCTUnwrap(source.range(of: "private func quitAndRelaunchAntigravityWithoutProxy()"))
        let nextFunctionRange = try XCTUnwrap(source.range(of: "private func enableTransparentRouting()"))
        let quitBody = String(source[quitRange.lowerBound..<nextFunctionRange.lowerBound])
        XCTAssertTrue(quitBody.contains("bundleURL = try preflightAntigravityBundleURL()"))
        XCTAssertTrue(quitBody.contains("try await relaunchAntigravityWithoutProxy(bundleURL: bundleURL)"))
        let relaunchRange = try XCTUnwrap(quitBody.range(of: "try await relaunchAntigravityWithoutProxy(bundleURL: bundleURL)"))
        let stopRange = try XCTUnwrap(quitBody.range(of: "runtime.stop()"))
        XCTAssertLessThan(relaunchRange.lowerBound, stopRange.lowerBound)

        XCTAssertTrue(source.contains("NSWorkspace.OpenConfiguration()"))
        XCTAssertTrue(source.contains("configuration.arguments = arguments"))
        XCTAssertTrue(source.contains("private func openAntigravity("))
        XCTAssertTrue(source.contains("try AntigravityUserSettings.applyLocalProxyOverrides(proxyPort: settings.localProxyPort)"))
        XCTAssertTrue(source.contains("try AntigravityUserSettings.removeLocalProxyOverrides(proxyPort: settings.localProxyPort)"))
        XCTAssertFalse(source.contains("try process.run()"))
        XCTAssertFalse(source.contains("forceTerminate()"))
        XCTAssertTrue(source.contains("Antigravity did not quit cleanly"))
    }

    func testDirectQuitRelaunchClearsPersistedLocalProxySettings() throws {
        let directory = try temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        try Data(
            #"""
            {
              "claudeCode.initialPermissionMode": "plan",
              "jetski.cloudCodeUrl": "https://127.0.0.1:8877",
              "http.proxy": "http://127.0.0.1:8877",
              "http.noProxy": ["localhost", "127.0.0.1"]
            }
            """#.utf8
        ).write(to: settingsURL)

        let changed = try AntigravityUserSettings.removeLocalProxyOverrides(
            settingsURL: settingsURL,
            proxyPort: 8877
        )

        XCTAssertTrue(changed)
        let data = try Data(contentsOf: settingsURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["jetski.cloudCodeUrl"])
        XCTAssertNil(object["http.proxy"])
        XCTAssertEqual(object["claudeCode.initialPermissionMode"] as? String, "plan")
        XCTAssertNotNil(object["http.noProxy"])
    }

    func testLaunchAppliesLocalCloudCodeEndpointOverride() throws {
        let directory = try temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        try Data(
            #"""
            {
              "claudeCode.initialPermissionMode": "plan",
              "jetski.cloudCodeUrl": "https://daily-cloudcode-pa.googleapis.com",
              "http.noProxy": ["localhost", "127.0.0.1"]
            }
            """#.utf8
        ).write(to: settingsURL)

        let changed = try AntigravityUserSettings.applyLocalProxyOverrides(
            settingsURL: settingsURL,
            proxyPort: 8877
        )

        XCTAssertTrue(changed)
        let data = try Data(contentsOf: settingsURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["jetski.cloudCodeUrl"] as? String, "https://127.0.0.1:8877")
        XCTAssertEqual(object["claudeCode.initialPermissionMode"] as? String, "plan")
        XCTAssertNotNil(object["http.noProxy"])
    }

    func testLaunchCreatesSettingsFileForLocalCloudCodeEndpointOverride() throws {
        let directory = try temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("User/settings.json")

        let changed = try AntigravityUserSettings.applyLocalProxyOverrides(
            settingsURL: settingsURL,
            proxyPort: 8877
        )

        XCTAssertTrue(changed)
        let data = try Data(contentsOf: settingsURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["jetski.cloudCodeUrl"] as? String, "https://127.0.0.1:8877")
    }

    func testDirectQuitRelaunchKeepsUnrelatedProxySettings() throws {
        let directory = try temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        try Data(
            #"""
            {
              "jetski.cloudCodeUrl": "https://cloudcode-pa.googleapis.com",
              "http.proxy": "http://proxy.example:8080"
            }
            """#.utf8
        ).write(to: settingsURL)

        let changed = try AntigravityUserSettings.removeLocalProxyOverrides(
            settingsURL: settingsURL,
            proxyPort: 8877
        )

        XCTAssertFalse(changed)
        let data = try Data(contentsOf: settingsURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["jetski.cloudCodeUrl"] as? String, "https://cloudcode-pa.googleapis.com")
        XCTAssertEqual(object["http.proxy"] as? String, "http://proxy.example:8080")
    }

    func testProviderReachabilityIsProbedInsteadOfStayingUnchecked() throws {
        let runtimeSource = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/PorterRuntimeController.swift"))
        let appSource = try String(contentsOf: packageRoot().appendingPathComponent("Sources/AntigravityPorterApp/AntigravityPorterApp.swift"))

        XCTAssertTrue(runtimeSource.contains("func refreshProviderReachability(settings: PorterSettings)"))
        XCTAssertTrue(runtimeSource.contains("status.providerReachability = .checking"))
        XCTAssertTrue(runtimeSource.contains("status.providerReachability = .reachable"))
        XCTAssertTrue(runtimeSource.contains("status.providerReachability = .unreachable(message)"))
        XCTAssertTrue(runtimeSource.contains("nextProviderReachabilityGeneration()"))
        XCTAssertTrue(runtimeSource.contains("isCurrentProviderReachabilityGeneration(generation)"))
        XCTAssertTrue(appSource.contains("runtime.refreshProviderReachability(settings: updated)"))
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

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRouterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
