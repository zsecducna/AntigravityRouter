import AntigravityPorterCore
import AppKit
import SwiftUI

private enum PorterRuntimeRegistry {
    static let shared = PorterRuntimeController()
}

@MainActor
private enum AppUpdateRegistry {
    static let shared = AppUpdateController()
}

final class PorterAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UserDefaultsSettingsStore()
        let settings = AntigravityRouterApp.settingsForNewLaunch(store: store)
        PorterRuntimeRegistry.shared.start(settings: settings)
        Task { @MainActor in
            AppUpdateRegistry.shared.startAutomaticChecks()
        }
    }
}

@main
struct AntigravityRouterApp: App {
    private let settingsStore = UserDefaultsSettingsStore()
    private let keychainStore = SecurityKeychainStore()
    private let certificateAuthority: CertificateAuthority
    @NSApplicationDelegateAdaptor(PorterAppDelegate.self) private var appDelegate
    @StateObject private var runtime = PorterRuntimeRegistry.shared
    @StateObject private var updater = AppUpdateRegistry.shared
    @State private var settings: PorterSettings
    @State private var selectedTab = PorterTab.status
    @State private var providerModels: [ProviderModel] = []
    @State private var modelsMessage = "Not loaded"
    @State private var modelsLoadFailed = false
    @State private var modelsLoading = false
    @State private var baseURLText: String
    @State private var proxyPortText: String
    @State private var apiKey: String
    @State private var certificateInstallMessage = ""
    @State private var certificateInstallFailed = false
    @State private var transparentRoutingMessage = ""
    @State private var transparentRoutingFailed = false
    @State private var launchMessage = ""
    @State private var launchFailed = false
    @State private var unsafeLogConfirmationPending = false
    @State private var quitConfirmationPending = false
    @State private var launchedAntigravityProcess: Process?

    init() {
        let settingsStore = UserDefaultsSettingsStore()
        self.certificateAuthority = CertificateAuthority(keychain: Self.certificateAuthorityStore())
        let loaded = Self.settingsForNewLaunch(store: settingsStore)
        _settings = State(initialValue: loaded)
        _baseURLText = State(initialValue: loaded.cheapRouterBaseURL.absoluteString)
        _proxyPortText = State(initialValue: "\(loaded.localProxyPort)")
        let savedAPIKey = (try? SecurityKeychainStore().string(for: .cheapRouterAPIKey)) ?? ""
        _apiKey = State(initialValue: savedAPIKey)
        PorterRuntimeRegistry.shared.start(settings: loaded)
    }

    var body: some Scene {
        MenuBarExtra("AntigravityRouter", systemImage: "point.3.connected.trianglepath.dotted") {
            TabView(selection: $selectedTab) {
                statusTab
                    .tabItem { Label("Status", systemImage: "circle.grid.cross") }
                    .tag(PorterTab.status)
                modelsTab
                    .tabItem { Label("Models", systemImage: "switch.2") }
                    .tag(PorterTab.models)
                settingsTab
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(PorterTab.settings)
                logTab
                    .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
                    .tag(PorterTab.log)
            }
            .padding(12)
            .frame(width: 460, height: 520)
            .onChange(of: settings) { _, newValue in
                try? settingsStore.save(newValue)
            }
            .onChange(of: settings.localProxyPort) { _, newValue in
                proxyPortText = "\(newValue)"
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var statusTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(PorterSettings.routingControlLabel, isOn: Binding(
                get: { runtime.status.proxyEnabled },
                set: { runtime.setProxyEnabled($0, settings: settings) }
            ))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                statusRow("MITM", runtime.status.proxyEnabled ? "On" : "Off")
                statusRow("App version", updater.currentVersionDisplay)
                statusRow("Updates", updater.statusMessage)
                statusRow("Custom provider", settings.customProviderRoutingEnabled ? "enabled" : "disabled")
                statusRow(PorterSettings.proxyListenLabel, "\(settings.localProxyHost):\(settings.localProxyPort)")
                statusRow(providerStatusLabel, runtime.status.providerReachability.displayText)
                statusRow(PorterSettings.proxyConnectsLabel, "\(runtime.status.totalRequests)")
                statusRow(PorterSettings.targetInferenceConnectsLabel, "\(runtime.status.targetInferenceConnects)")
                statusRow(PorterSettings.otherHTTPSConnectsLabel, "\(runtime.status.blindTunnelConnects)")
                statusRow(PorterSettings.routedRequestsLabel, "\(runtime.status.routedRequests)")
                statusRow(PorterSettings.directRequestsLabel, "\(runtime.status.googleDirectRequests)")
                if let lastError = runtime.status.lastError {
                    statusRow("Last error", lastError)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Button("Check for Updates", systemImage: "arrow.down.circle") {
                    updater.checkNow(forceOpen: true)
                }
                .help("Check GitHub releases now; automatic checks run every hour")
                .disabled(updater.isChecking)
                Text(updater.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Button(
                    settings.customProviderRoutingEnabled ? "Disable Custom Provider Routing" : "Enable Custom Provider Routing",
                    systemImage: settings.customProviderRoutingEnabled ? "xmark.circle" : "checkmark.circle"
                ) {
                    settings.customProviderRoutingEnabled.toggle()
                }
                .help(settings.customProviderRoutingEnabled ? "Forward all model requests to Google direct" : "Route all supported model requests to the custom provider")
                if !transparentRoutingMessage.isEmpty {
                    Text(transparentRoutingMessage)
                        .font(.caption)
                        .foregroundStyle(transparentRoutingFailed ? .red : .secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Button("Relaunch Antigravity", systemImage: "arrow.clockwise") {
                    launchAntigravityViaPorter()
                }
                .help("Quit existing Antigravity and start its app binary with proxy env plus Electron proxy arguments")
                if !launchMessage.isEmpty {
                    Text(launchMessage)
                        .font(.caption)
                        .foregroundStyle(launchFailed ? .red : .secondary)
                }
            }
            Spacer()
            Button("Quit", systemImage: "power") {
                quitConfirmationPending = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Quit AntigravityRouter?", isPresented: $quitConfirmationPending) {
            Button("Quit and Relaunch Antigravity", role: .destructive) {
                quitAndRelaunchAntigravityWithoutProxy()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Antigravity will relaunch without proxy settings. If relaunch succeeds, the local proxy will stop and AntigravityRouter will quit.")
        }
    }

    private var modelsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.cheapRouterBaseURL.appendingPathComponent("v1/models").absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if !modelsMessage.isEmpty {
                        Text(modelsMessage)
                            .font(.caption)
                            .foregroundStyle(modelsLoadFailed ? .red : .secondary)
                    }
                }
                Spacer()
                Button("", systemImage: "arrow.clockwise") {
                    refreshProviderModels()
                }
                .help("Refresh provider models")
                .disabled(modelsLoading)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(providerModels) { model in
                        modelRow(model)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if providerModels.isEmpty {
                refreshProviderModels()
            }
        }
    }

    private func modelRow(_ model: ProviderModel) -> some View {
        HStack(spacing: 10) {
            Text(model.id)
                .font(.system(.body, design: .monospaced))

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var settingsTab: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("cheaprouter.uk")
                TextField("Base URL", text: $baseURLText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if let url = URL(string: baseURLText), url.scheme == "https" {
                            var updated = settings
                            updated.cheapRouterBaseURL = url
                            settings = updated
                            runtime.refreshProviderReachability(settings: updated)
                        }
                    }
            }
            GridRow {
                Text("API key")
                HStack {
                    SecureField("Bearer token", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveAPIKey)
                    Button("", systemImage: "checkmark") {
                        saveAPIKey()
                    }
                    .help("Save API key")
                }
            }
            GridRow {
                Text("Local proxy port")
                HStack {
                    TextField("8877", text: $proxyPortText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 96)
                        .onChange(of: proxyPortText) { _, newValue in
                            normalizeProxyPortText(newValue)
                        }
                        .onSubmit(commitProxyPortText)
                        .help("Enter a local proxy port between 1024 and 65535")
                    Stepper("", value: $settings.localProxyPort, in: 1024...65535)
                        .labelsHidden()
                        .help("Adjust local proxy port")
                }
            }
            GridRow {
                Text("Launch at login")
                Toggle("", isOn: $settings.launchAtLoginEnabled)
                    .toggleStyle(.switch)
            }
            GridRow {
                Text("Raw HTTP log")
                Toggle("", isOn: $settings.rawHTTPLoggingEnabled)
                    .toggleStyle(.switch)
                    .help("Store and display redacted HTTP request/response metadata")
            }
            GridRow {
                Text("Unsafe full body log")
                Toggle("", isOn: Binding(
                    get: { settings.unsafeFullRawHTTPLoggingEnabled },
                    set: { enabled in
                        if enabled {
                            unsafeLogConfirmationPending = true
                        } else {
                            settings.unsafeFullRawHTTPLoggingEnabled = false
                        }
                    }
                ))
                    .toggleStyle(.switch)
                    .help("Store full HTTP bodies with a size cap; may expose tokens and prompts")
            }
            GridRow {
                Text("Tail log lines")
                Stepper(value: $settings.logTailLineLimit, in: 10...1000, step: 10) {
                    Text("\(settings.logTailLineLimit)")
                        .font(.system(.body, design: .monospaced))
                }
            }
            GridRow {
                Text("CA certificate")
                VStack(alignment: .leading, spacing: 6) {
                    Button("Install CA", systemImage: "key") {
                        installCertificate()
                    }
                    .help("Install and trust the CA certificate for this user")
                    if !certificateInstallMessage.isEmpty {
                        Text(certificateInstallMessage)
                            .font(.caption)
                            .foregroundStyle(certificateInstallFailed ? .red : .secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Enable unsafe full body log?", isPresented: $unsafeLogConfirmationPending) {
            Button("Enable", role: .destructive) {
                settings.unsafeFullRawHTTPLoggingEnabled = true
            }
            Button("Cancel", role: .cancel) {
                settings.unsafeFullRawHTTPLoggingEnabled = false
            }
        } message: {
            Text("Full prompt and response bodies will be stored in local logs until disabled or the app restarts.")
        }
    }

    private var logTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Showing last \(visibleLogLines.count) / \(runtime.status.recentLogLines.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Truncate", systemImage: "trash") {
                    runtime.truncateLogs()
                }
                .help("Clear displayed logs and truncate runtime/raw HTTP log files")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if visibleLogLines.isEmpty {
                        Text("No requests")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleLogLines, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var visibleLogLines: [String] {
        let limit = max(1, settings.logTailLineLimit)
        let lines = runtime.status.recentLogLines
        if lines.count <= limit {
            return lines
        }
        return Array(lines.suffix(limit))
    }

    private var providerStatusLabel: String {
        settings.cheapRouterBaseURL.host(percentEncoded: false) ?? "Target provider"
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? keychainStore.delete(.cheapRouterAPIKey)
        } else {
            try? keychainStore.setString(trimmed, for: .cheapRouterAPIKey)
        }
        apiKey = trimmed
    }

    private func normalizeProxyPortText(_ value: String) {
        let digits = value.filter(\.isNumber)
        if digits != value {
            proxyPortText = digits
            return
        }
        guard let port = Int(digits), (1024...65535).contains(port) else {
            return
        }
        settings.localProxyPort = port
    }

    private func commitProxyPortText() {
        guard let port = Int(proxyPortText) else {
            proxyPortText = "\(settings.localProxyPort)"
            return
        }
        let normalized = min(max(port, 1024), 65535)
        settings.localProxyPort = normalized
        proxyPortText = "\(normalized)"
    }

    private func launchAntigravityViaPorter() {
        launchFailed = false
        launchMessage = "Starting local proxy listener..."
        runtime.waitUntilReady(settings: settings, timeout: 5) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    do {
                        launchedAntigravityProcess = try launchAntigravity()
                        launchFailed = false
                        launchMessage = "Relaunched with proxy env + Electron proxy"
                    } catch {
                        launchFailed = true
                        launchMessage = "Launch failed: \(error.localizedDescription)"
                    }
                case let .failure(error):
                    launchFailed = true
                    launchMessage = "Proxy not ready: \(error.localizedDescription)"
                }
            }
        }
    }

    private func quitAndRelaunchAntigravityWithoutProxy() {
        let bundleURL: URL
        do {
            bundleURL = try preflightAntigravityBundleURL()
        } catch {
            launchFailed = true
            launchMessage = "Direct relaunch failed: \(error.localizedDescription)"
            return
        }
        launchFailed = false
        launchMessage = "Relaunching Antigravity without proxy..."
        Task { @MainActor in
            do {
                try await relaunchAntigravityWithoutProxy(bundleURL: bundleURL)
                runtime.stop()
                NSApplication.shared.terminate(nil)
            } catch {
                launchFailed = true
                launchMessage = "Direct relaunch failed: \(error.localizedDescription)"
            }
        }
    }

    private func enableTransparentRouting() {
        transparentRoutingFailed = false
        transparentRoutingMessage = "Requesting admin approval..."
        let proxyPort = settings.localProxyPort
        runtime.waitUntilReady(settings: settings, timeout: 5) { result in
            Task.detached {
                do {
                    switch result {
                    case .success:
                        try TransparentRoutingManager().enable(proxyPort: proxyPort)
                        await MainActor.run {
                            transparentRoutingFailed = false
                            transparentRoutingMessage = "Native routing enabled for CloudCode hosts"
                        }
                    case let .failure(error):
                        await MainActor.run {
                            transparentRoutingFailed = true
                            transparentRoutingMessage = "Proxy not ready: \(error.localizedDescription)"
                        }
                    }
                } catch {
                    await MainActor.run {
                        transparentRoutingFailed = true
                        transparentRoutingMessage = "Native routing failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func disableTransparentRouting() {
        transparentRoutingFailed = false
        transparentRoutingMessage = "Requesting admin approval..."
        Task.detached {
            do {
                try TransparentRoutingManager().disable()
                await MainActor.run {
                    transparentRoutingFailed = false
                    transparentRoutingMessage = "Native routing disabled"
                }
            } catch {
                await MainActor.run {
                    transparentRoutingFailed = true
                    transparentRoutingMessage = "Disable failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func launchAntigravity() throws -> Process {
        let caDER = try certificateAuthority.exportSigningIdentityDER()
        let caPEMURL = try writeCertificatePEMForRuntime(caDER)
        let plan = AntigravityLaunchPlan.make(
            proxyHost: "localhost",
            proxyPort: settings.localProxyPort,
            extraEnvironment: [
                "NODE_EXTRA_CA_CERTS": caPEMURL.path,
                "SSL_CERT_FILE": caPEMURL.path,
                "REQUESTS_CA_BUNDLE": caPEMURL.path,
                "GRPC_DEFAULT_SSL_ROOTS_FILE_PATH": caPEMURL.path,
                "CURL_CA_BUNDLE": caPEMURL.path
            ]
        )
        guard FileManager.default.isExecutableFile(atPath: plan.executableURL.path) else {
            throw NSError(
                domain: "AntigravityRouter.Launch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing executable \(plan.executableURL.path)"]
            )
        }
        try terminateRunningAntigravity()

        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        try process.run()
        return process
    }

    private func preflightAntigravityBundleURL() throws -> URL {
        let bundleURL = AntigravityLaunchPlan.defaultBundleURL
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw NSError(
                domain: "AntigravityRouter.Launch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing app \(bundleURL.path)"]
            )
        }
        return bundleURL
    }

    private func relaunchAntigravityWithoutProxy(bundleURL: URL) async throws {
        try terminateRunningAntigravity()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.environment = Self.environmentWithoutProxy()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func terminateRunningAntigravity() throws {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: AntigravityLaunchPlan.bundleIdentifier)
        guard !runningApps.isEmpty else { return }

        for app in runningApps where !app.isTerminated {
            app.terminate()
        }

        let deadline = Date().addingTimeInterval(5)
        while runningApps.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        for app in runningApps where !app.isTerminated {
            app.forceTerminate()
        }

        let forcedDeadline = Date().addingTimeInterval(3)
        while runningApps.contains(where: { !$0.isTerminated }) && Date() < forcedDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        if runningApps.contains(where: { !$0.isTerminated }) {
            throw NSError(
                domain: "AntigravityRouter.Launch",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Antigravity did not quit cleanly"]
            )
        }
    }

    private func refreshProviderModels() {
        modelsLoading = true
        modelsLoadFailed = false
        modelsMessage = "Loading..."
        let settings = settings
        Task {
            do {
                guard let apiKey = try keychainStore.string(for: .cheapRouterAPIKey),
                      !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw CheapRouterClientError.badStatus(401)
                }
                let client = CheapRouterClient(configuration: .init(baseURL: settings.cheapRouterBaseURL, apiKey: apiKey))
                let models = try await client.fetchModels()
                await MainActor.run {
                    providerModels = models
                    modelsMessage = "\(models.count) models from target provider"
                    modelsLoadFailed = false
                    modelsLoading = false
                }
            } catch {
                await MainActor.run {
                    providerModels = []
                    modelsMessage = "Model fetch failed: \(error.localizedDescription)"
                    modelsLoadFailed = true
                    modelsLoading = false
                }
            }
        }
    }

    private func installCertificate() {
        do {
            let certificateDER = try certificateAuthority.exportSigningIdentityDER()
            let certificateURL = try writeCertificateForTrustSetup(certificateDER)
            certificateInstallFailed = false
            certificateInstallMessage = "Requesting trust approval..."
            Task {
                do {
                    try await CertificateTrustInstaller().installAndTrust(certificateURL: certificateURL)
                    await MainActor.run {
                        certificateInstallFailed = false
                        certificateInstallMessage = "CA installed and trusted"
                    }
                } catch {
                    await MainActor.run {
                        certificateInstallFailed = true
                        certificateInstallMessage = "Install failed: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            certificateInstallFailed = true
            certificateInstallMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    private func writeCertificateForTrustSetup(_ certificateDER: Data) throws -> URL {
        let supportRoot = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = supportRoot.appendingPathComponent("AntigravityPorter", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let certificateURL = appDirectory.appendingPathComponent("AntigravityRouter Local CA.cer")
        try certificateDER.write(to: certificateURL, options: .atomic)
        return certificateURL
    }

    private func writeCertificatePEMForRuntime(_ certificateDER: Data) throws -> URL {
        let supportRoot = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = supportRoot.appendingPathComponent("AntigravityPorter", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let certificateURL = appDirectory.appendingPathComponent("AntigravityRouter Local CA.pem")
        let base64 = certificateDER.base64EncodedString(options: [.lineLength64Characters])
        let pem = "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
        try Data(pem.utf8).write(to: certificateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certificateURL.path)
        return certificateURL
    }

    static func settingsForNewLaunch(store: UserDefaultsSettingsStore) -> PorterSettings {
        let loaded = store.load()
        let sanitized = loaded.disablingUnsafeFullRawHTTPLoggingForNewLaunch()
        if sanitized != loaded {
            try? store.save(sanitized)
        }
        return sanitized
    }

    private static func certificateAuthorityStore() -> any KeychainStoring {
        MigratingKeychainStore(
            primary: SecurityKeychainStore(service: "uk.cheaprouter.AntigravityPorter.ca"),
            fallback: FileKeychainStore(directory: legacyCertificateAuthorityDirectory())
        )
    }

    private static func legacyCertificateAuthorityDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AntigravityPorter/CertificateAuthority", isDirectory: true)
    }

    private static func environmentWithoutProxy() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "NO_PROXY",
            "http_proxy",
            "https_proxy",
            "all_proxy",
            "no_proxy",
            "NODE_EXTRA_CA_CERTS",
            "SSL_CERT_FILE",
            "REQUESTS_CA_BUNDLE",
            "GRPC_DEFAULT_SSL_ROOTS_FILE_PATH",
            "CURL_CA_BUNDLE"
        ] {
            environment.removeValue(forKey: key)
        }
        return environment
    }
}

struct PorterAppStatus {
    var proxyEnabled = false
    var providerReachability: ProviderReachabilityState = .unchecked
    var totalRequests = 0
    var targetInferenceConnects = 0
    var blindTunnelConnects = 0
    var routedRequests = 0
    var googleDirectRequests = 0
    var recentLogLines: [String] = []
    var lastError: String?
}

enum ProviderReachabilityState: Equatable, Sendable {
    case unchecked
    case checking
    case reachable
    case unreachable(String)

    var displayText: String {
        switch self {
        case .unchecked:
            "unchecked"
        case .checking:
            "checking"
        case .reachable:
            "reachable"
        case .unreachable:
            "unreachable"
        }
    }
}

private enum PorterTab: Hashable {
    case status
    case models
    case settings
    case log
}
