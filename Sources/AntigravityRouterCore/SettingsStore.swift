import Foundation

public struct TargetProviderConfig: Codable, Equatable, Identifiable, Sendable {
    public static let defaultProviderID = "cheaprouter"

    public var id: String
    public var baseURL: URL
    public var enabled: Bool

    public init(id: String, baseURL: URL, enabled: Bool = true) {
        self.id = Self.normalizedProviderID(id) ?? Self.defaultProviderID
        self.baseURL = baseURL
        self.enabled = enabled
    }

    public static func normalizedProviderID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty,
              id.count <= 48,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return id
    }
}

public struct ProviderModelAlias: Codable, Equatable, ExpressibleByStringLiteral, Sendable {
    public var providerID: String
    public var modelID: String

    public init(providerID: String = TargetProviderConfig.defaultProviderID, modelID: String) {
        self.providerID = TargetProviderConfig.normalizedProviderID(providerID) ?? providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = modelID
    }

    public init(stringLiteral value: String) {
        self.init(modelID: value)
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case modelID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawProviderID = try container.decode(String.self, forKey: .providerID)
        guard let providerID = TargetProviderConfig.normalizedProviderID(rawProviderID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .providerID,
                in: container,
                debugDescription: "providerID is invalid"
            )
        }
        let modelID = try container.decode(String.self, forKey: .modelID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .modelID,
                in: container,
                debugDescription: "modelID is empty"
            )
        }
        self.providerID = providerID
        self.modelID = modelID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(modelID, forKey: .modelID)
    }
}

public struct PorterSettings: Codable, Equatable, Sendable {
    public static let defaultProxyHost = "127.0.0.1"
    public static let defaultProxyPort = 8877
    public static let defaultCheapRouterBaseURL = URL(string: "https://cheaprouter.uk")!
    public static let routingControlLabel = "Local proxy listener"
    public static let proxyListenLabel = "Local proxy"
    public static let proxyConnectsLabel = "Proxy CONNECTs today"
    public static let targetInferenceConnectsLabel = "Target Google API CONNECTs"
    public static let otherHTTPSConnectsLabel = "Other HTTPS CONNECTs"
    public static let routedRequestsLabel = "Routed model requests"
    public static let directRequestsLabel = "Direct Google model requests"
    public static let defaultLogTailLineLimit = 200

    public static var defaults: PorterSettings {
        PorterSettings(
            cheapRouterBaseURL: defaultCheapRouterBaseURL,
            localProxyHost: defaultProxyHost,
            localProxyPort: defaultProxyPort,
            launchAtLoginEnabled: false,
            customProviderRoutingEnabled: false,
            loggingEnabled: true,
            rawHTTPLoggingEnabled: true,
            unsafeFullRawHTTPLoggingEnabled: false,
            logTailLineLimit: defaultLogTailLineLimit,
            targetProviders: [TargetProviderConfig(id: TargetProviderConfig.defaultProviderID, baseURL: defaultCheapRouterBaseURL)],
            providerModelAliases: [:]
        )
    }

    public var cheapRouterBaseURL: URL
    public var localProxyHost: String
    public var localProxyPort: Int
    public var launchAtLoginEnabled: Bool
    public var customProviderRoutingEnabled: Bool
    public var loggingEnabled: Bool
    public var rawHTTPLoggingEnabled: Bool
    public var unsafeFullRawHTTPLoggingEnabled: Bool
    public var logTailLineLimit: Int
    public var targetProviders: [TargetProviderConfig]
    public var providerModelAliases: [String: ProviderModelAlias]

    public init(
        cheapRouterBaseURL: URL,
        localProxyHost: String,
        localProxyPort: Int,
        launchAtLoginEnabled: Bool,
        customProviderRoutingEnabled: Bool = false,
        loggingEnabled: Bool = true,
        rawHTTPLoggingEnabled: Bool = true,
        unsafeFullRawHTTPLoggingEnabled: Bool = false,
        logTailLineLimit: Int = defaultLogTailLineLimit,
        targetProviders: [TargetProviderConfig]? = nil,
        providerModelAliases: [String: ProviderModelAlias] = [:]
    ) {
        self.cheapRouterBaseURL = cheapRouterBaseURL
        self.localProxyHost = localProxyHost
        self.localProxyPort = localProxyPort
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.customProviderRoutingEnabled = customProviderRoutingEnabled
        self.loggingEnabled = loggingEnabled
        self.rawHTTPLoggingEnabled = rawHTTPLoggingEnabled
        self.unsafeFullRawHTTPLoggingEnabled = unsafeFullRawHTTPLoggingEnabled
        self.logTailLineLimit = Self.normalizeLogTailLineLimit(logTailLineLimit)
        self.targetProviders = Self.normalizedTargetProviders(
            targetProviders ?? [TargetProviderConfig(id: TargetProviderConfig.defaultProviderID, baseURL: cheapRouterBaseURL)],
            fallbackBaseURL: cheapRouterBaseURL
        )
        self.providerModelAliases = providerModelAliases
    }

    private enum CodingKeys: String, CodingKey {
        case cheapRouterBaseURL
        case localProxyHost
        case localProxyPort
        case launchAtLoginEnabled
        case customProviderRoutingEnabled
        case loggingEnabled
        case rawHTTPLoggingEnabled
        case unsafeFullRawHTTPLoggingEnabled
        case logTailLineLimit
        case targetProviders
        case providerModelAliases
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case routedModels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try? decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyRoutedModels = (try? legacyContainer?.decodeIfPresent([String].self, forKey: .routedModels)) ?? nil
        let migratedRoutingEnabled = legacyRoutedModels?.isEmpty == false
        self.init(
            cheapRouterBaseURL: try container.decode(URL.self, forKey: .cheapRouterBaseURL),
            localProxyHost: try container.decode(String.self, forKey: .localProxyHost),
            localProxyPort: try container.decode(Int.self, forKey: .localProxyPort),
            launchAtLoginEnabled: try container.decode(Bool.self, forKey: .launchAtLoginEnabled),
            customProviderRoutingEnabled: try container.decodeIfPresent(Bool.self, forKey: .customProviderRoutingEnabled) ?? migratedRoutingEnabled,
            loggingEnabled: try container.decodeIfPresent(Bool.self, forKey: .loggingEnabled) ?? true,
            rawHTTPLoggingEnabled: try container.decodeIfPresent(Bool.self, forKey: .rawHTTPLoggingEnabled) ?? true,
            unsafeFullRawHTTPLoggingEnabled: try container.decodeIfPresent(Bool.self, forKey: .unsafeFullRawHTTPLoggingEnabled) ?? false,
            logTailLineLimit: try container.decodeIfPresent(Int.self, forKey: .logTailLineLimit) ?? Self.defaultLogTailLineLimit,
            targetProviders: try container.decodeIfPresent([TargetProviderConfig].self, forKey: .targetProviders),
            providerModelAliases: Self.decodeProviderModelAliases(from: container)
        )
    }

    private static func normalizeLogTailLineLimit(_ value: Int) -> Int {
        min(max(value, 10), 1000)
    }

    private static func normalizedTargetProviders(_ providers: [TargetProviderConfig], fallbackBaseURL: URL) -> [TargetProviderConfig] {
        var seen = Set<String>()
        let normalized = providers.compactMap { provider -> TargetProviderConfig? in
            guard let id = TargetProviderConfig.normalizedProviderID(provider.id),
                  !seen.contains(id)
            else { return nil }
            seen.insert(id)
            return TargetProviderConfig(id: id, baseURL: provider.baseURL, enabled: provider.enabled)
        }
        if normalized.isEmpty {
            return [TargetProviderConfig(id: TargetProviderConfig.defaultProviderID, baseURL: fallbackBaseURL)]
        }
        return normalized
    }

    private static func decodeProviderModelAliases(from container: KeyedDecodingContainer<CodingKeys>) -> [String: ProviderModelAlias] {
        do {
            if let aliases = try container.decodeIfPresent([String: ProviderModelAlias].self, forKey: .providerModelAliases) {
                return aliases
            }
        } catch {
            // Fall through to legacy [String: String] aliases.
        }
        let legacy = (try? container.decodeIfPresent([String: String].self, forKey: .providerModelAliases)) ?? nil
        return legacy?.mapValues { ProviderModelAlias(modelID: $0) } ?? [:]
    }

    public func disablingUnsafeFullRawHTTPLoggingForNewLaunch() -> PorterSettings {
        guard unsafeFullRawHTTPLoggingEnabled else { return self }
        var copy = self
        copy.unsafeFullRawHTTPLoggingEnabled = false
        return copy
    }
}

public protocol SettingsDataStoring: AnyObject {
    func settingsData(forKey key: String) -> Data?
    func setSettingsData(_ value: Data, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: SettingsDataStoring {
    public func settingsData(forKey key: String) -> Data? {
        data(forKey: key)
    }

    public func setSettingsData(_ value: Data, forKey key: String) {
        set(value, forKey: key)
    }
}

public final class UserDefaultsSettingsStore {
    public static let defaultSettingsKey = "AntigravityRouter.settings.v1"
    public static let legacySettingsKey = "AntigravityPorter.settings.v1"

    private let userDefaults: any SettingsDataStoring
    private let key: String
    private let legacyKey: String?

    public init(
        userDefaults: any SettingsDataStoring = UserDefaults.standard,
        key: String = UserDefaultsSettingsStore.defaultSettingsKey,
        legacyKey: String? = UserDefaultsSettingsStore.legacySettingsKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.legacyKey = legacyKey
    }

    public func load() -> PorterSettings {
        if let settings = loadSettings(forKey: key) {
            return settings
        }
        if let legacyKey, let settings = loadSettings(forKey: legacyKey) {
            try? save(settings)
            userDefaults.removeObject(forKey: legacyKey)
            return settings
        }
        return .defaults
    }

    public func save(_ settings: PorterSettings) throws {
        let data = try JSONEncoder().encode(settings)
        userDefaults.setSettingsData(data, forKey: key)
        if let legacyKey {
            userDefaults.removeObject(forKey: legacyKey)
        }
    }

    public func reset() {
        userDefaults.removeObject(forKey: key)
        if let legacyKey {
            userDefaults.removeObject(forKey: legacyKey)
        }
    }

    private func loadSettings(forKey key: String) -> PorterSettings? {
        guard let data = userDefaults.settingsData(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(PorterSettings.self, from: data)
    }
}
