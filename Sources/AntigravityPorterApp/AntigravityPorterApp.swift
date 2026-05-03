import AntigravityPorterCore
import SwiftUI

@main
struct AntigravityPorterApp: App {
    private let settingsStore = UserDefaultsSettingsStore()
    private let keychainStore = SecurityKeychainStore()
    @State private var status = PorterAppStatus()
    @State private var settings: PorterSettings
    @State private var selectedTab = PorterTab.status
    @State private var manualModel = ""
    @State private var baseURLText: String
    @State private var apiKey: String

    init() {
        let loaded = UserDefaultsSettingsStore().load()
        _settings = State(initialValue: loaded)
        _baseURLText = State(initialValue: loaded.cheapRouterBaseURL.absoluteString)
        _apiKey = State(initialValue: (try? SecurityKeychainStore().string(for: .cheapRouterAPIKey)) ?? "")
    }

    var body: some Scene {
        MenuBarExtra("AntigravityPorter", systemImage: "point.3.connected.trianglepath.dotted") {
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
        }
    }

    private var statusTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Proxy", isOn: $status.proxyEnabled)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                statusRow("State", status.proxyEnabled ? "ON" : "OFF")
                statusRow("Listen", "\(settings.localProxyHost):\(settings.localProxyPort)")
                statusRow("cheaprouter.uk", status.cheapRouterReachable ? "reachable" : "unchecked")
                statusRow("Requests today", "\(status.totalRequests)")
                statusRow("Routed", "\(status.routedRequests)")
                statusRow("Google direct", "\(status.googleDirectRequests)")
            }
            Spacer()
            Button("Quit", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var modelsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Add model", text: $manualModel)
                    .textFieldStyle(.roundedBorder)
                Button("", systemImage: "plus") {
                    let added = settings.addManualModel(manualModel)
                    if added {
                        manualModel = ""
                    }
                }
                .help("Add model")
                .disabled(manualModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(settings.sortedKnownModels) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.id)
                                    .font(.system(.body, design: .monospaced))
                                Text(model.source.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { settings.routesViaCheapRouter(modelID: model.id) },
                                set: { settings.setRouteViaCheapRouter($0, for: model.id) }
                            ))
                            .toggleStyle(.switch)
                            .help(settings.routesViaCheapRouter(modelID: model.id) ? "Route via cheaprouter.uk" : "Use Google directly")
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var settingsTab: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("cheaprouter.uk")
                TextField("Base URL", text: $baseURLText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if let url = URL(string: baseURLText), url.scheme == "https" {
                            settings.cheapRouterBaseURL = url
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
                Text("Port")
                Stepper(value: $settings.localProxyPort, in: 1024...65535) {
                    Text("\(settings.localProxyPort)")
                        .font(.system(.body, design: .monospaced))
                }
            }
            GridRow {
                Text("Launch at login")
                Toggle("", isOn: $settings.launchAtLoginEnabled)
                    .toggleStyle(.switch)
            }
            GridRow {
                Text("CA certificate")
                Button("Install", systemImage: "key") {}
                    .help("Install CA certificate")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var logTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if status.recentLogLines.isEmpty {
                    Text("No requests")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(status.recentLogLines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
}

private struct PorterAppStatus {
    var proxyEnabled = false
    var cheapRouterReachable = false
    var totalRequests = 0
    var routedRequests = 0
    var googleDirectRequests = 0
    var recentLogLines: [String] = []
}

private enum PorterTab: Hashable {
    case status
    case models
    case settings
    case log
}
