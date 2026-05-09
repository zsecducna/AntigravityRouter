import AntigravityRouterCore
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
    private static let currentKeychainService = "uk.cheaprouter.AntigravityRouter"
    private static let legacyKeychainService = "uk.cheaprouter.AntigravityPorter"
    private static let currentCAKeychainService = "uk.cheaprouter.AntigravityRouter.ca"
    private static let legacyCAKeychainService = "uk.cheaprouter.AntigravityPorter.ca"
    private static let mainWindowWidth: CGFloat = 560
    private static let mainWindowHeight: CGFloat = 660
    private static let setupWizardWindowWidth: CGFloat = 520
    private static let setupWizardWindowHeight: CGFloat = 560
    private let settingsStore = UserDefaultsSettingsStore()
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
    @State private var selectedProviderID: String
    @State private var providerIDText: String
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
    @State private var logExportMessage = ""
    @State private var logExportFailed = false

    init() {
        let settingsStore = UserDefaultsSettingsStore()
        self.certificateAuthority = CertificateAuthority(keychain: Self.certificateAuthorityStore())
        let loaded = Self.settingsForNewLaunch(store: settingsStore)
        let firstProvider = loaded.targetProviders.first ?? TargetProviderConfig(id: TargetProviderConfig.defaultProviderID, baseURL: loaded.cheapRouterBaseURL)
        _settings = State(initialValue: loaded)
        _selectedProviderID = State(initialValue: firstProvider.id)
        _providerIDText = State(initialValue: firstProvider.id)
        _baseURLText = State(initialValue: firstProvider.baseURL.absoluteString)
        _proxyPortText = State(initialValue: "\(loaded.localProxyPort)")
        _apiKey = State(initialValue: "")
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
            .onChange(of: providerIDText) { _, _ in
                invalidateProviderModelsCheck()
            }
            .onChange(of: apiKey) { _, _ in
                invalidateProviderModelsCheck()
            }
            .onChange(of: selectedProviderID) { _, _ in
                syncSelectedProviderFields()
            }
            .task {
                loadSavedAPIKey()
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
                Text("AntigravityRouter adds target-provider models to Antigravity and routes only those selected models to the provider.")
                Text("Google catalog models stay Google-direct. Provider model discovery patches Antigravity's Google model list without replacing it.")
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
                    Text("Provider ID")
                    TextField("cheaprouter", text: $providerIDText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            _ = commitProviderConfigurationFields()
                        }
                }
                GridRow {
                    Text("Provider URL")
                    TextField("https://cheaprouter.uk", text: $baseURLText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            _ = commitProviderConfigurationFields()
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
                Text("Finishing enables provider models, starts the local MITM listener, and relaunches Antigravity with the router proxy environment.")
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
                statusRow("Provider models", settings.customProviderRoutingEnabled ? "enabled" : "disabled")
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
                    Text(settings.targetProviders.filter(\.enabled).map { "\($0.id): \($0.baseURL.appendingPathComponent("v1/models").absoluteString)" }.joined(separator: "  "))
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
                Text("Provider")
                Picker("", selection: $selectedProviderID) {
                    ForEach(settings.targetProviders) { provider in
                        Text(provider.id).tag(provider.id)
                    }
                }
                .labelsHidden()
            }
            GridRow {
                Text("Provider ID")
                TextField("cheaprouter", text: $providerIDText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        _ = commitProviderConfigurationFields()
                    }
            }
            GridRow {
                Text("Provider URL")
                TextField("Base URL", text: $baseURLText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        _ = commitProviderConfigurationFields()
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
                Text("Provider config")
                HStack {
                    Button("Save Provider", systemImage: "checkmark") {
                        _ = saveProviderConfiguration()
                    }
                    Button("Add Provider", systemImage: "plus") {
                        addProvider()
                    }
                    Button("Remove", systemImage: "minus") {
                        removeSelectedProvider()
                    }
                    .disabled(settings.targetProviders.count <= 1)
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
                Text("Logging")
                Toggle("", isOn: $settings.loggingEnabled)
                    .toggleStyle(.switch)
                    .help("Store and display runtime and raw HTTP logs")
            }
            GridRow {
                Text("Raw HTTP log")
                Toggle("", isOn: $settings.rawHTTPLoggingEnabled)
                    .toggleStyle(.switch)
                    .help("Store and display redacted HTTP request/response metadata")
                    .disabled(!settings.loggingEnabled)
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
                    .disabled(!settings.loggingEnabled)
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
                Button("Export", systemImage: "square.and.arrow.up") {
                    exportLogs()
                }
                .help("Export runtime and raw HTTP log files")
                Button("Truncate", systemImage: "trash") {
                    runtime.truncateLogs()
                }
                .help("Clear displayed logs and truncate runtime/raw HTTP log files")
            }
            if !logExportMessage.isEmpty {
                Text(logExportMessage)
                    .font(.caption)
                    .foregroundStyle(logExportFailed ? .red : .secondary)
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

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.title = "Export Logs"
        panel.nameFieldStringValue = "antigravityrouter-logs.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try runtime.exportLogs(to: destination)
            logExportMessage = "Exported logs to \(destination.lastPathComponent)"
            logExportFailed = false
        } catch {
            logExportMessage = "Export failed: \(error.localizedDescription)"
            logExportFailed = true
        }
    }

    private var providerStatusLabel: String {
        selectedProvider?.id ?? "Target provider"
    }

    private var selectedProvider: TargetProviderConfig? {
        settings.targetProviders.first { $0.id == selectedProviderID }
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
    private func commitProviderConfigurationFields() -> Bool {
        guard let providerID = TargetProviderConfig.normalizedProviderID(providerIDText) else {
            providerModelsCheckSucceeded = false
            providerModels = []
            modelsLoadFailed = true
            modelsMessage = "Provider ID must use letters, numbers, dash, or underscore"
            return false
        }
        guard let url = URL(string: baseURLText), isSupportedProviderURL(url) else {
            providerModelsCheckSucceeded = false
            providerModels = []
            modelsLoadFailed = true
            modelsMessage = "Provider URL must use HTTPS, except loopback HTTP"
            return false
        }
        modelsLoadFailed = false
        var updated = settings
        let oldProviderID = selectedProviderID
        if providerID != oldProviderID, updated.targetProviders.contains(where: { $0.id == providerID }) {
            providerModelsCheckSucceeded = false
            providerModels = []
            modelsLoadFailed = true
            modelsMessage = "Provider ID already exists"
            return false
        }
        let oldProvider = updated.targetProviders.first { $0.id == oldProviderID }
        if providerID != oldProviderID || url != oldProvider?.baseURL {
            removeProviderModelAliases(from: &updated, for: [oldProviderID, providerID])
        }
        if let index = updated.targetProviders.firstIndex(where: { $0.id == oldProviderID }) {
            updated.targetProviders[index] = TargetProviderConfig(id: providerID, baseURL: url, enabled: true)
        } else {
            updated.targetProviders.append(TargetProviderConfig(id: providerID, baseURL: url, enabled: true))
        }
        if providerID == TargetProviderConfig.defaultProviderID || oldProviderID == TargetProviderConfig.defaultProviderID || updated.targetProviders.first?.id == providerID {
            updated.cheapRouterBaseURL = url
        }
        settings = updated
        selectedProviderID = providerID
        providerIDText = providerID
        if providerID != oldProviderID {
            migrateProviderAPIKey(from: oldProviderID, to: providerID)
        }
        runtime.refreshProviderReachability(settings: updated)
        return true
    }

    private func isSupportedProviderURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty
        else { return false }
        if scheme == "https" { return true }
        if scheme == "http", Self.loopbackProviderHosts.contains(host) { return true }
        return false
    }

    private static let loopbackProviderHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    private func selectedProviderKeychainStore() -> any KeychainStoring {
        Self.providerKeychainStore(providerID: selectedProviderID)
    }

    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous: String
        do {
            previous = try selectedProviderKeychainStore().string(for: .cheapRouterAPIKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            previous = ""
        }
        if trimmed.isEmpty {
            try? selectedProviderKeychainStore().delete(.cheapRouterAPIKey)
        } else {
            try? selectedProviderKeychainStore().setString(trimmed, for: .cheapRouterAPIKey)
        }
        if trimmed != previous {
            clearProviderModelAliases(for: [selectedProviderID])
        }
        apiKey = trimmed
    }

    private func migrateProviderAPIKey(from oldProviderID: String, to newProviderID: String) {
        let oldStore = Self.providerKeychainStore(providerID: oldProviderID)
        let newStore = Self.providerKeychainStore(providerID: newProviderID)
        let visibleKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingKey = (try? oldStore.string(for: .cheapRouterAPIKey))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keyToMigrate = visibleKey.isEmpty ? existingKey : visibleKey
        if keyToMigrate.isEmpty {
            try? newStore.delete(.cheapRouterAPIKey)
        } else {
            try? newStore.setString(keyToMigrate, for: .cheapRouterAPIKey)
        }
        try? oldStore.delete(.cheapRouterAPIKey)
        apiKey = keyToMigrate
    }

    private func clearProviderModelAliases(for providerIDs: Set<String>) {
        guard !settings.providerModelAliases.isEmpty else { return }
        var updated = settings
        removeProviderModelAliases(from: &updated, for: providerIDs)
        settings = updated
        try? settingsStore.save(updated)
    }

    private func removeProviderModelAliases(from settings: inout PorterSettings, for providerIDs: Set<String>) {
        guard !providerIDs.isEmpty else { return }
        settings.providerModelAliases = settings.providerModelAliases.filter { !providerIDs.contains($0.value.providerID) }
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
        guard commitProviderConfigurationFields() else { return false }
        saveAPIKey()
        return true
    }

    private func addProvider() {
        var updated = settings
        let base = TargetProviderConfig.defaultProviderID
        var suffix = 2
        var id = "\(base)-\(suffix)"
        while updated.targetProviders.contains(where: { $0.id == id }) {
            suffix += 1
            id = "\(base)-\(suffix)"
        }
        updated.targetProviders.append(TargetProviderConfig(id: id, baseURL: PorterSettings.defaultCheapRouterBaseURL))
        updated.providerModelAliases = [:]
        settings = updated
        selectedProviderID = id
        providerIDText = id
        baseURLText = PorterSettings.defaultCheapRouterBaseURL.absoluteString
        apiKey = ""
        invalidateProviderModelsCheck()
    }

    private func removeSelectedProvider() {
        guard settings.targetProviders.count > 1 else { return }
        var updated = settings
        updated.targetProviders.removeAll { $0.id == selectedProviderID }
        updated.providerModelAliases = [:]
        if !updated.targetProviders.contains(where: { $0.id == selectedProviderID }) {
            selectedProviderID = updated.targetProviders.first?.id ?? TargetProviderConfig.defaultProviderID
        }
        settings = updated
        syncSelectedProviderFields()
        invalidateProviderModelsCheck()
    }

    private func syncSelectedProviderFields() {
        guard let provider = selectedProvider else { return }
        providerIDText = provider.id
        baseURLText = provider.baseURL.absoluteString
        apiKey = ""
        loadSavedAPIKey()
    }

    private func checkProviderConfiguration() {
        guard saveProviderConfiguration() else { return }
        refreshProviderModels()
    }

    private func loadSavedAPIKey() {
        guard apiKey.isEmpty else { return }
        Task.detached {
            let providerID = await MainActor.run { selectedProviderID }
            let savedAPIKey = (try? Self.providerKeychainStore(providerID: providerID).string(for: .cheapRouterAPIKey)) ?? ""
            guard !savedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await MainActor.run {
                apiKey = savedAPIKey
                if UserDefaults.standard.object(forKey: Self.setupWizardCompletedKey) == nil {
                    UserDefaults.standard.set(true, forKey: Self.setupWizardCompletedKey)
                }
            }
        }
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
        try AntigravityUserSettings.applyLocalProxyOverrides(proxyPort: settings.localProxyPort)

        do {
            return try await openAntigravity(
                bundleURL: bundleURL,
                arguments: plan.arguments,
                environment: plan.environment
            )
        } catch {
            _ = try? AntigravityUserSettings.removeLocalProxyOverrides(proxyPort: settings.localProxyPort)
            throw error
        }
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
        guard commitProviderConfigurationFields() else { return }
        modelsLoading = true
        modelsLoadFailed = false
        providerModelsCheckSucceeded = false
        modelsMessage = "Loading..."
        let settings = settings
        Task {
            var loadedModels: [ProviderModel] = []
            var failures: [String] = []
            do {
                for provider in settings.targetProviders where provider.enabled {
                    guard let apiKey = try Self.providerKeychainStore(providerID: provider.id).string(for: .cheapRouterAPIKey),
                          !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else {
                        failures.append("\(provider.id): missing key")
                        continue
                    }
                    let client = CheapRouterClient(configuration: .init(baseURL: provider.baseURL, apiKey: apiKey))
                    do {
                        let models = try await client.fetchModels()
                        loadedModels += models.map { ProviderModel(id: "\(provider.id)/\($0.id)") }
                    } catch {
                        failures.append("\(provider.id): \(error.localizedDescription)")
                    }
                }
                guard !loadedModels.isEmpty else {
                    throw CheapRouterClientError.badStatus(401)
                }
                await MainActor.run {
                    providerModels = loadedModels
                    modelsMessage = failures.isEmpty
                        ? "\(loadedModels.count) models from \(settings.targetProviders.filter(\.enabled).count) provider(s)"
                        : "\(loadedModels.count) models; \(failures.joined(separator: "; "))"
                    modelsLoadFailed = !failures.isEmpty
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
                defer { try? FileManager.default.removeItem(at: certificateURL) }
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
        let appDirectory = supportRoot.appendingPathComponent("AntigravityRouter", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDirectory.path)
        let certificateURL = appDirectory.appendingPathComponent("AntigravityRouter Local CA-\(UUID().uuidString).cer")
        try certificateDER.write(to: certificateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certificateURL.path)
        return certificateURL
    }

    private func writeCertificatePEMForRuntime(_ certificateDER: Data) throws -> URL {
        let supportRoot = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = supportRoot.appendingPathComponent("AntigravityRouter", isDirectory: true)
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
            primary: FileKeychainStore(directory: certificateAuthorityDirectory()),
            fallback: MigratingKeychainStore(
                primary: SecurityKeychainStore(service: currentCAKeychainService),
                fallback: SecurityKeychainStore(service: legacyCAKeychainService)
            )
        )
    }

    nonisolated private static func appSecretsStore() -> any KeychainStoring {
        MigratingKeychainStore(
            primary: SecurityKeychainStore(service: "uk.cheaprouter.AntigravityRouter"),
            fallback: SecurityKeychainStore(service: "uk.cheaprouter.AntigravityPorter")
        )
    }

    nonisolated private static func providerKeychainStore(providerID: String) -> any KeychainStoring {
        let normalized = TargetProviderConfig.normalizedProviderID(providerID) ?? TargetProviderConfig.defaultProviderID
        if normalized == TargetProviderConfig.defaultProviderID {
            return appSecretsStore()
        }
        return MigratingKeychainStore(
            primary: SecurityKeychainStore(service: providerKeychainService(providerID: normalized, legacy: false)),
            fallback: SecurityKeychainStore(service: providerKeychainService(providerID: normalized, legacy: true))
        )
    }

    nonisolated private static func providerKeychainService(providerID: String, legacy: Bool) -> String {
        let prefix = legacy ? "uk.cheaprouter.AntigravityPorter.provider" : "uk.cheaprouter.AntigravityRouter.provider"
        return "\(prefix).\(providerID)"
    }

    private static func certificateAuthorityDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AntigravityRouter/CertificateAuthority", isDirectory: true)
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
