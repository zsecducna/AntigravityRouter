import Foundation

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
            routedModels: [],
            rawHTTPLoggingEnabled: true,
            unsafeFullRawHTTPLoggingEnabled: false,
            logTailLineLimit: defaultLogTailLineLimit
        )
    }

    public var cheapRouterBaseURL: URL
    public var localProxyHost: String
    public var localProxyPort: Int
    public var launchAtLoginEnabled: Bool
    public var customProviderRoutingEnabled: Bool
    public var routedModels: Set<String>
    public var rawHTTPLoggingEnabled: Bool
    public var unsafeFullRawHTTPLoggingEnabled: Bool
    public var logTailLineLimit: Int

    public init(
        cheapRouterBaseURL: URL,
        localProxyHost: String,
        localProxyPort: Int,
        launchAtLoginEnabled: Bool,
        customProviderRoutingEnabled: Bool = false,
        routedModels: Set<String>,
        rawHTTPLoggingEnabled: Bool = true,
        unsafeFullRawHTTPLoggingEnabled: Bool = false,
        logTailLineLimit: Int = defaultLogTailLineLimit
    ) {
        self.cheapRouterBaseURL = cheapRouterBaseURL
        self.localProxyHost = localProxyHost
        self.localProxyPort = localProxyPort
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.customProviderRoutingEnabled = customProviderRoutingEnabled
        self.routedModels = Set(routedModels.map(Self.normalizeModelID).filter { !$0.isEmpty })
        self.rawHTTPLoggingEnabled = rawHTTPLoggingEnabled
        self.unsafeFullRawHTTPLoggingEnabled = unsafeFullRawHTTPLoggingEnabled
        self.logTailLineLimit = Self.normalizeLogTailLineLimit(logTailLineLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case cheapRouterBaseURL
        case localProxyHost
        case localProxyPort
        case launchAtLoginEnabled
        case customProviderRoutingEnabled
        case routedModels
        case rawHTTPLoggingEnabled
        case unsafeFullRawHTTPLoggingEnabled
        case logTailLineLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cheapRouterBaseURL: try container.decode(URL.self, forKey: .cheapRouterBaseURL),
            localProxyHost: try container.decode(String.self, forKey: .localProxyHost),
            localProxyPort: try container.decode(Int.self, forKey: .localProxyPort),
            launchAtLoginEnabled: try container.decode(Bool.self, forKey: .launchAtLoginEnabled),
            customProviderRoutingEnabled: try container.decodeIfPresent(Bool.self, forKey: .customProviderRoutingEnabled) ?? false,
            routedModels: try container.decodeIfPresent(Set<String>.self, forKey: .routedModels) ?? [],
            rawHTTPLoggingEnabled: try container.decodeIfPresent(Bool.self, forKey: .rawHTTPLoggingEnabled) ?? true,
            unsafeFullRawHTTPLoggingEnabled: try container.decodeIfPresent(Bool.self, forKey: .unsafeFullRawHTTPLoggingEnabled) ?? false,
            logTailLineLimit: try container.decodeIfPresent(Int.self, forKey: .logTailLineLimit) ?? Self.defaultLogTailLineLimit
        )
    }

    public func routesViaCheapRouter(modelID: String) -> Bool {
        routedModels.contains(Self.normalizeModelID(modelID))
    }

    public mutating func setRouteViaCheapRouter(_ enabled: Bool, for modelID: String) {
        let normalized = Self.normalizeModelID(modelID)
        guard !normalized.isEmpty else { return }
        if enabled {
            routedModels.insert(normalized)
        } else {
            routedModels.remove(normalized)
        }
    }

    private static func normalizeModelID(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeLogTailLineLimit(_ value: Int) -> Int {
        min(max(value, 10), 1000)
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
    private let userDefaults: any SettingsDataStoring
    private let key: String

    public init(userDefaults: any SettingsDataStoring = UserDefaults.standard, key: String = "AntigravityPorter.settings.v1") {
        self.userDefaults = userDefaults
        self.key = key
    }

    public func load() -> PorterSettings {
        guard let data = userDefaults.settingsData(forKey: key),
              let settings = try? JSONDecoder().decode(PorterSettings.self, from: data)
        else {
            return .defaults
        }
        return settings
    }

    public func save(_ settings: PorterSettings) throws {
        let data = try JSONEncoder().encode(settings)
        userDefaults.setSettingsData(data, forKey: key)
    }

    public func reset() {
        userDefaults.removeObject(forKey: key)
    }
}
