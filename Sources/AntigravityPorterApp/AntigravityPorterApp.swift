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
    private static let setupWizardCompletedKey = "AntigravityRouter.setupWizardCompleted.v1"
    private static let mainWindowWidth: CGFloat = 560
    private static let mainWindowHeight: CGFloat = 660
    private static let setupWizardWindowWidth: CGFloat = 520
    private static let setupWizardWindowHeight: CGFloat = 560
    private let settingsStore = UserDefaultsSettingsStore()
    private let keychainStore = SecurityKeychainStore()
    private let certificateAuthority: CertificateAuthority
    @NSApplicationDelegateAdaptor(PorterAppDelegate.self) private var appDelegate
    @AppStorage(Self.setupWizardCompletedKey) private var setupWizardCompleted = false
    @StateObject private var runtime = PorterRuntimeRegistry.shared
    @StateObject private var updater = AppUpdateRegistry.shared
    @State private var settings: PorterSettings
    @State private var selectedTab = PorterTab.status
    @State private var setupWizardStep = SetupWizardStep.welcome
    @State private var providerModels: [ProviderModel] = []
    @State private var modelsMessage = "Not loaded"
    @State private var modelsLoadFailed = false
    @State private var modelsLoading = false
    @State private var providerModelsCheckSucceeded = false
    @State private var baseURLText: String
    @State private var proxyPortText: String
    @State private var apiKey: String
    @State private var certificateInstallMessage = ""
    @State private var certificateInstallFailed = false
    @State private var certificateInstallSucceeded = false
    @State private var transparentRoutingMessage = ""
    @State private var transparentRoutingFailed = false
    @State private var launchMessage = ""
    @State private var launchFailed = false
    @State private var unsafeLogConfirmationPending = false
    @State private var quitConfirmationPending = false
    @State private var launchedAntigravityApp: NSRunningApplication?

    init() {
        let settingsStore = UserDefaultsSettingsStore()
        self.certificateAuthority = CertificateAuthority(keychain: Self.certificateAuthorityStore())
        let loaded = Self.settingsForNewLaunch(store: settingsStore)
        _settings = State(initialValue: loaded)
        _baseURLText = State(initialValue: loaded.cheapRouterBaseURL.absoluteString)
        _proxyPortText = State(initialValue: "\(loaded.localProxyPort)")
        let savedAPIKey = (try? SecurityKeychainStore().string(for: .cheapRouterAPIKey)) ?? ""
        if UserDefaults.standard.object(forKey: Self.setupWizardCompletedKey) == nil,
           !savedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.set(true, forKey: Self.setupWizardCompletedKey)
        }
        _apiKey = State(initialValue: savedAPIKey)
        PorterRuntimeRegistry.shared.start(settings: loaded)
    }

    var body: some Scene {
        MenuBarExtra("AntigravityRouter", systemImage: "point.3.connected.trianglepath.dotted") {
            Group {
                if setupWizardCompleted {
                    mainTabs
                } else {
                    setupWizard
                }
            }
            .padding(12)
            .frame(
                width: setupWizardCompleted ? Self.mainWindowWidth : Self.setupWizardWindowWidth,
                height: setupWizardCompleted ? Self.mainWindowHeight : Self.setupWizardWindowHeight
            )
            .onChange(of: settings) { _, newValue in
                try? settingsStore.save(newValue)
            }
            .onChange(of: settings.localProxyPort) { _, newValue in
                proxyPortText = "\(newValue)"
            }
            .onChange(of: baseURLText) { _, _ in
                invalidateProviderModelsCheck()
            }
            .onChange(of: apiKey) { _, _ in
                invalidateProviderModelsCheck()
            }
            .onChange(of: selectedTab) { _, newValue in
                if newValue == .status || newValue == .models {
                    commitProviderBaseURLIfValid()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var mainTabs: some View {
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
    }

    private var setupWizard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(setupWizardStep.title)
                        .font(.title3.weight(.semibold))
                    Text("Step \(setupWizardStep.index + 1) of \(SetupWizardStep.steps.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Skip", systemImage: "xmark.circle") {
                    setupWizardCompleted = true
                }
                .buttonStyle(.borderless)
                .help("Skip setup and open the main controls")
            }

            ProgressView(value: Double(setupWizardStep.index + 1), total: Double(SetupWizardStep.steps.count))

            setupWizardStepContent

            Spacer()

            HStack {
                if setupWizardStep != .welcome {
                    Button("Back", systemImage: "chevron.left") {
                        setupWizardStep = setupWizardStep.previous
                    }
                }
                Spacer()
                setupWizardPrimaryButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var setupWizardStepContent: some View {
        switch setupWizardStep {
        case .welcome:
            VStack(alignment: .leading, spacing: 10) {
                Text("AntigravityRouter prepares Antigravity to use a custom provider for supported model requests.")
                Text("Model discovery stays Google-direct. Only supported inference requests are translated and routed when custom provider routing is enabled.")
                    .foregroundStyle(.secondary)
                Text("The setup checks the local CA, provider credentials, model list, and then relaunches Antigravity with the proxy environment.")
                    .foregroundStyle(.secondary)
            }
        case .certificate:
            VStack(alignment: .leading, spacing: 10) {
                Text("Generate and install the local CA certificate so Antigravity can trust the router's MITM TLS certificates.")
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
        case .provider:
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Provider URL")
                    TextField("https://cheaprouter.uk", text: $baseURLText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            _ = commitProviderBaseURL()
                        }
                }
                GridRow {
                    Text("API key")
                    SecureField("Bearer token", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveAPIKey)
                }
            }
            Text("Your API key is stored in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .check:
            VStack(alignment: .leading, spacing: 10) {
                Button("Check API Key and Fetch Models", systemImage: "checkmark.seal") {
                    checkProviderConfiguration()
                }
                .disabled(modelsLoading)
                Text(modelsMessage)
                    .font(.caption)
                    .foregroundStyle(modelsLoadFailed ? .red : .secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(providerModels.prefix(12)) { model in
                            Text(model.id)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if providerModels.count > 12 {
                            Text("+ \(providerModels.count - 12) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .finish:
            VStack(alignment: .leading, spacing: 10) {
                Text("Setup is ready.")
                Text("Finishing enables custom provider routing, starts the local MITM listener, and relaunches Antigravity with the router proxy environment.")
                    .foregroundStyle(.secondary)
                if !launchMessage.isEmpty {
                    Text(launchMessage)
                        .font(.caption)
                        .foregroundStyle(launchFailed ? .red : .secondary)
                }
            }
        }
    }

    private var setupWizardPrimaryButton: some View {
        Group {
            switch setupWizardStep {
            case .welcome:
                Button("Start Setup", systemImage: "chevron.right") {
                    setupWizardStep = setupWizardStep.next
                }
            case .certificate:
                Button("Continue", systemImage: "chevron.right") {
                    setupWizardStep = setupWizardStep.next
                }
                .disabled(!certificateInstallSucceeded)
            case .provider:
                Button("Continue", systemImage: "chevron.right") {
                    guard saveProviderConfiguration() else { return }
                    setupWizardStep = setupWizardStep.next
                }
            case .check:
                Button("Continue", systemImage: "chevron.right") {
                    setupWizardStep = setupWizardStep.next
                }
                .disabled(!providerModelsCheckSucceeded)
            case .finish:
                Button("Finish and Relaunch Antigravity", systemImage: "arrow.clockwise") {
                    finishSetupAndLaunchAntigravity()
                }
            }
        }
    }

    private var statusTab: some View {
        ScrollView {
            statusContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusContent: some View {
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
            if quitConfirmationPending {
                quitConfirmation
            } else {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var quitConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Quit AntigravityRouter?")
                .font(.headline)
            Text("Antigravity will relaunch without proxy settings. If relaunch succeeds, the local proxy will stop and AntigravityRouter will quit.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Quit and Relaunch Antigravity", systemImage: "power") {
                    quitConfirmationPending = false
                    quitAndRelaunchAntigravityWithoutProxy()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Cancel", systemImage: "xmark") {
                    quitConfirmationPending = false
                }
            }
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
                    Text("Provider URL")
                    TextField("Base URL", text: $baseURLText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            _ = commitProviderBaseURL()
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
                Text("Setup wizard")
                Button("Open Setup", systemImage: "list.bullet.clipboard") {
                    setupWizardStep = .welcome
                    setupWizardCompleted = false
                }
                .help("Run the guided setup again")
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
            if unsafeLogConfirmationPending {
                GridRow {
                    Text("")
                    unsafeFullBodyLogConfirmation
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
    }

    private var unsafeFullBodyLogConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full prompt and response bodies will be stored in local logs until disabled or the app restarts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Enable", systemImage: "exclamationmark.triangle") {
                    settings.unsafeFullRawHTTPLoggingEnabled = true
                    unsafeLogConfirmationPending = false
                }
                .buttonStyle(.borderedProminent)
                .help("Enable full HTTP body logging")
                Button("Cancel", systemImage: "xmark") {
                    settings.unsafeFullRawHTTPLoggingEnabled = false
                    unsafeLogConfirmationPending = false
                }
                .help("Keep full HTTP body logging disabled")
            }
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

    @discardableResult
    private func commitProviderBaseURL() -> Bool {
        guard let url = URL(string: baseURLText), isSupportedProviderURLScheme(url.scheme) else {
            providerModelsCheckSucceeded = false
            providerModels = []
            modelsLoadFailed = true
            modelsMessage = "Provider URL must use HTTP or HTTPS"
            return false
        }
        modelsLoadFailed = false
        var updated = settings
        updated.cheapRouterBaseURL = url
        settings = updated
        runtime.refreshProviderReachability(settings: updated)
        return true
    }

    @discardableResult
    private func commitProviderBaseURLIfValid() -> Bool {
        guard let url = URL(string: baseURLText), isSupportedProviderURLScheme(url.scheme) else {
            return false
        }
        guard url != settings.cheapRouterBaseURL else {
            return true
        }
        var updated = settings
        updated.cheapRouterBaseURL = url
        settings = updated
        runtime.refreshProviderReachability(settings: updated)
        return true
    }

    private func isSupportedProviderURLScheme(_ scheme: String?) -> Bool {
        scheme == "http" || scheme == "https"
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

    private func invalidateProviderModelsCheck() {
        providerModelsCheckSucceeded = false
        providerModels = []
        guard !modelsLoading else { return }
        modelsLoadFailed = false
        modelsMessage = "Not checked"
    }

    @discardableResult
    private func saveProviderConfiguration() -> Bool {
        guard commitProviderBaseURL() else { return false }
        saveAPIKey()
        return true
    }

    private func checkProviderConfiguration() {
        guard saveProviderConfiguration() else { return }
        refreshProviderModels()
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

    private func launchAntigravityViaPorter(completeSetupOnSuccess: Bool = false) {
        launchFailed = false
        launchMessage = "Starting local proxy listener..."
        runtime.waitUntilReady(settings: settings, timeout: 5) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    do {
                        launchedAntigravityApp = try await launchAntigravity()
                        launchFailed = false
                        launchMessage = "Relaunched with proxy env + Electron proxy"
                        if completeSetupOnSuccess {
                            setupWizardCompleted = true
                            setupWizardStep = .welcome
                        }
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

    private func finishSetupAndLaunchAntigravity() {
        guard saveProviderConfiguration() else { return }
        var updated = settings
        updated.customProviderRoutingEnabled = true
        do {
            try settingsStore.save(updated)
        } catch {
            launchFailed = true
            launchMessage = "Settings save failed: \(error.localizedDescription)"
            return
        }
        settings = updated
        launchAntigravityViaPorter(completeSetupOnSuccess: true)
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

    private func launchAntigravity() async throws -> NSRunningApplication? {
        let bundleURL = try preflightAntigravityBundleURL()
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

        return try await openAntigravity(
            bundleURL: bundleURL,
            arguments: plan.arguments,
            environment: plan.environment
        )
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
        try AntigravityUserSettings.removeLocalProxyOverrides(proxyPort: settings.localProxyPort)
        _ = try await openAntigravity(
            bundleURL: bundleURL,
            arguments: [],
            environment: Self.environmentWithoutProxy()
        )
    }

    private func openAntigravity(
        bundleURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = arguments
        configuration.environment = environment
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSRunningApplication?, any Error>) in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { runningApp, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: runningApp)
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

        let deadline = Date().addingTimeInterval(20)
        while runningApps.contains(where: { !$0.isTerminated }) && Date() < deadline {
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
        guard commitProviderBaseURL() else { return }
        modelsLoading = true
        modelsLoadFailed = false
        providerModelsCheckSucceeded = false
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
                    providerModelsCheckSucceeded = true
                    modelsLoading = false
                }
            } catch {
                await MainActor.run {
                    providerModels = []
                    modelsMessage = "Model fetch failed: \(error.localizedDescription)"
                    modelsLoadFailed = true
                    providerModelsCheckSucceeded = false
                    modelsLoading = false
                }
            }
        }
    }

    private func installCertificate() {
        do {
            let certificateDER = try certificateAuthority.exportSigningIdentityDER()
            let certificateURL = try writeCertificateForTrustSetup(certificateDER)
            certificateInstallSucceeded = false
            certificateInstallFailed = false
            certificateInstallMessage = "Requesting trust approval..."
            Task {
                do {
                    try await CertificateTrustInstaller().installAndTrust(certificateURL: certificateURL)
                    await MainActor.run {
                        certificateInstallSucceeded = true
                        certificateInstallFailed = false
                        certificateInstallMessage = "CA installed and trusted"
                    }
                } catch {
                    await MainActor.run {
                        certificateInstallSucceeded = false
                        certificateInstallFailed = true
                        certificateInstallMessage = "Install failed: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            certificateInstallSucceeded = false
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

private enum SetupWizardStep: Int, CaseIterable, Hashable {
    case welcome
    case certificate
    case provider
    case check
    case finish

    static let steps: [SetupWizardStep] = Array(allCases)

    var index: Int {
        Self.steps.firstIndex(of: self) ?? 0
    }

    var previous: SetupWizardStep {
        Self.steps[max(0, index - 1)]
    }

    var next: SetupWizardStep {
        Self.steps[min(Self.steps.count - 1, index + 1)]
    }

    var title: String {
        switch self {
        case .welcome:
            "Welcome"
        case .certificate:
            "Generate and Install Certs"
        case .provider:
            "Configure Custom Provider"
        case .check:
            "Check API Key and Models"
        case .finish:
            "Finish"
        }
    }
}

private enum PorterTab: Hashable {
    case status
    case models
    case settings
    case log
}
