import Foundation

public struct AntigravityLaunchPlan: Equatable, Sendable {
    public static let defaultBundleURL = URL(fileURLWithPath: "/Applications/Antigravity.app", isDirectory: true)
    public static let bundleIdentifier = "com.google.antigravity"

    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }

    public static func make(
        bundleURL: URL = defaultBundleURL,
        proxyHost: String,
        proxyPort: Int,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        extraEnvironment: [String: String] = [:]
    ) -> AntigravityLaunchPlan {
        let proxyURL = "http://\(proxyHost):\(proxyPort)"
        let environment = baseEnvironment
            .merging(ProxyEnvironment.variables(proxyHost: proxyHost, proxyPort: proxyPort), uniquingKeysWith: { _, proxyValue in proxyValue })
            .merging(extraEnvironment, uniquingKeysWith: { _, extraValue in extraValue })
        return AntigravityLaunchPlan(
            executableURL: bundleURL.appendingPathComponent("Contents/MacOS/Electron"),
            arguments: [
                "--proxy-server=\(proxyURL)",
                "--proxy-bypass-list=\(ProxyEnvironment.chromiumBypassList)"
            ],
            environment: environment
        )
    }
}
