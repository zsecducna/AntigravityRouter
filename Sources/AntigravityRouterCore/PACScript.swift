import Foundation

public enum PACScript {
    public static let targetHosts = [
        "cloudcode-pa.googleapis.com",
        "daily-cloudcode-pa.googleapis.com"
    ]

    public static func generate(proxyHost: String, proxyPort: Int) -> String {
        let directive = "PROXY \(proxyHost):\(proxyPort)"
        let hostChecks = targetHosts
            .map { "    host === \"\(javascriptEscaped($0))\"" }
            .joined(separator: " ||\n")

        return """
        function FindProxyForURL(url, host) {
          host = (host || "").toLowerCase();
          if (
        \(hostChecks)
          ) {
            return "\(javascriptEscaped(directive))";
          }
          return "DIRECT";
        }
        """
    }

    private static func javascriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
