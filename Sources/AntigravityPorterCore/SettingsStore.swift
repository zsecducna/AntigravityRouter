import Foundation

public enum KnownModelSource: String, Codable, Equatable, Sendable {
    case builtIn
    case seenInTraffic
    case manual
}

public struct KnownModel: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var source: KnownModelSource
    public var firstSeenAt: Date?

    public init(id: String, source: KnownModelSource, firstSeenAt: Date? = nil) {
        self.id = id
        self.source = source
        self.firstSeenAt = firstSeenAt
    }
}

public struct PorterSettings: Codable, Equatable, Sendable {
    public static let defaultProxyHost = "127.0.0.1"
    public static let defaultProxyPort = 8877
    public static let defaultCheapRouterBaseURL = URL(string: "https://cheaprouter.uk")!

    public static let builtInModelIDs = [
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.0-flash",
        "gemini-1.5-pro",
        "gemini-1.5-flash",
        "claude-opus-4",
        "claude-sonnet-4",
        "claude-haiku-4"
    ]

    public static var defaults: PorterSettings {
        PorterSettings(
            cheapRouterBaseURL: defaultCheapRouterBaseURL,
            localProxyHost: defaultProxyHost,
            localProxyPort: defaultProxyPort,
            launchAtLoginEnabled: false,
            knownModels: builtInModelIDs.map { KnownModel(id: $0, source: .builtIn) },
            routedModels: []
        )
    }

    public var cheapRouterBaseURL: URL
    public var localProxyHost: String
    public var localProxyPort: Int
    public var launchAtLoginEnabled: Bool
    public var knownModels: [KnownModel]
    public var routedModels: Set<String>

    public init(
        cheapRouterBaseURL: URL,
        localProxyHost: String,
        localProxyPort: Int,
        launchAtLoginEnabled: Bool,
        knownModels: [KnownModel],
        routedModels: Set<String>
    ) {
        self.cheapRouterBaseURL = cheapRouterBaseURL
        self.localProxyHost = localProxyHost
        self.localProxyPort = localProxyPort
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.knownModels = Self.deduplicate(models: knownModels)
        self.routedModels = routedModels
    }

    public var sortedKnownModels: [KnownModel] {
        knownModels.sorted { lhs, rhs in
            if lhs.source == rhs.source {
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            return sourceRank(lhs.source) < sourceRank(rhs.source)
        }
    }

    public func routesViaCheapRouter(modelID: String) -> Bool {
        routedModels.contains(modelID)
    }

    public mutating func setRouteViaCheapRouter(_ enabled: Bool, for modelID: String) {
        addKnownModelIfNeeded(modelID, source: .manual, firstSeenAt: nil)
        if enabled {
            routedModels.insert(modelID)
        } else {
            routedModels.remove(modelID)
        }
    }

    @discardableResult
    public mutating func registerSeenModel(_ modelID: String, at date: Date = Date()) -> Bool {
        addKnownModelIfNeeded(modelID, source: .seenInTraffic, firstSeenAt: date)
    }

    @discardableResult
    public mutating func addManualModel(_ modelID: String) -> Bool {
        addKnownModelIfNeeded(modelID, source: .manual, firstSeenAt: nil)
    }

    @discardableResult
    private mutating func addKnownModelIfNeeded(_ modelID: String, source: KnownModelSource, firstSeenAt: Date?) -> Bool {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        guard !knownModels.contains(where: { $0.id == normalized }) else { return false }
        knownModels.append(KnownModel(id: normalized, source: source, firstSeenAt: firstSeenAt))
        knownModels = Self.deduplicate(models: knownModels)
        return true
    }

    private static func deduplicate(models: [KnownModel]) -> [KnownModel] {
        var seen = Set<String>()
        return models.filter { model in
            seen.insert(model.id).inserted
        }
    }

    private func sourceRank(_ source: KnownModelSource) -> Int {
        switch source {
        case .builtIn: 0
        case .seenInTraffic: 1
        case .manual: 2
        }
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
        return mergeBuiltIns(into: settings)
    }

    public func save(_ settings: PorterSettings) throws {
        let data = try JSONEncoder().encode(mergeBuiltIns(into: settings))
        userDefaults.setSettingsData(data, forKey: key)
    }

    public func reset() {
        userDefaults.removeObject(forKey: key)
    }

    private func mergeBuiltIns(into settings: PorterSettings) -> PorterSettings {
        var merged = settings
        for modelID in PorterSettings.builtInModelIDs {
            if !merged.knownModels.contains(where: { $0.id == modelID }) {
                merged.knownModels.append(KnownModel(id: modelID, source: .builtIn))
            }
        }
        return PorterSettings(
            cheapRouterBaseURL: merged.cheapRouterBaseURL,
            localProxyHost: merged.localProxyHost,
            localProxyPort: merged.localProxyPort,
            launchAtLoginEnabled: merged.launchAtLoginEnabled,
            knownModels: merged.knownModels,
            routedModels: merged.routedModels
        )
    }
}
