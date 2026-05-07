import Foundation

enum AntigravityUserSettings {
    static func defaultSettingsURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Antigravity/User", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @discardableResult
    static func applyLocalProxyOverrides(settingsURL: URL = defaultSettingsURL(), proxyPort: Int) throws -> Bool {
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } else {
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let localCloudCodeURL = "https://127.0.0.1:\(proxyPort)"
        guard object["jetski.cloudCodeUrl"] as? String != localCloudCodeURL else { return false }
        object["jetski.cloudCodeUrl"] = localCloudCodeURL

        let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: settingsURL, options: .atomic)
        return true
    }

    @discardableResult
    static func removeLocalProxyOverrides(settingsURL: URL = defaultSettingsURL(), proxyPort: Int) throws -> Bool {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return false }
        let data = try Data(contentsOf: settingsURL)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        var changed = false
        for key in ["jetski.cloudCodeUrl", "http.proxy"] {
            guard let value = object[key] as? String,
                  isLocalProxyURL(value, proxyPort: proxyPort)
            else { continue }
            object.removeValue(forKey: key)
            changed = true
        }

        guard changed else { return false }
        let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: settingsURL, options: .atomic)
        return true
    }

    private static func isLocalProxyURL(_ value: String, proxyPort: Int) -> Bool {
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased(),
              components.port == proxyPort
        else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}
