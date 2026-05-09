import Foundation

public enum ProxyEnvironment {
    public static let noProxyList = [
        "localhost",
        "127.0.0.1",
        "::1",
        "cheaprouter.uk",
        "accounts.google.com",
        "oauth2.googleapis.com",
        "www.googleapis.com",
        "google.com",
        ".google.com"
    ].joined(separator: ",")
    public static let chromiumBypassList = [
        "localhost",
        "127.0.0.1",
        "::1",
        "cheaprouter.uk",
        "accounts.google.com",
        "oauth2.googleapis.com",
        "www.googleapis.com",
        "*.google.com"
    ].joined(separator: ";")

    public static func variables(proxyHost: String, proxyPort: Int) -> [String: String] {
        let proxyURL = "http://\(proxyHost):\(proxyPort)"
        return [
            "HTTP_PROXY": proxyURL,
            "HTTPS_PROXY": proxyURL,
            "ALL_PROXY": proxyURL,
            "NO_PROXY": noProxyList,
            "http_proxy": proxyURL,
            "https_proxy": proxyURL,
            "all_proxy": proxyURL,
            "no_proxy": noProxyList
        ]
    }
}
