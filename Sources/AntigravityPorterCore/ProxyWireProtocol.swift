import Foundation

public enum ProxyListenerPlan: Equatable, Sendable {
    public static func loopbackHosts(for host: String) -> [String] {
        switch host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "127.0.0.1", "localhost":
            ["127.0.0.1", "::1"]
        case "::1":
            ["::1"]
        default:
            [host]
        }
    }
}

public enum ProxyWireProtocol: Sendable {
    public static let connectEstablished = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)

    public static func plainHTTPResponse(
        status: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    public static func pacResponse(method: String, script: String) -> Data {
        plainHTTPResponse(
            status: "200 OK",
            headers: [
                "Cache-Control": "no-store",
                "Content-Type": "application/x-ns-proxy-autoconfig"
            ],
            body: method.uppercased() == "GET" ? Data(script.utf8) : Data()
        )
    }
}

public struct ProxyCleanupPlan: Equatable, Sendable {
    public var closesClient: Bool
    public var closesRelay: Bool
    public var closesTLSConnection: Bool
    public var closesTLSListener: Bool
    public var logPhase: String

    public init(
        closesClient: Bool = true,
        closesRelay: Bool = true,
        closesTLSConnection: Bool = true,
        closesTLSListener: Bool = true,
        logPhase: String
    ) {
        self.closesClient = closesClient
        self.closesRelay = closesRelay
        self.closesTLSConnection = closesTLSConnection
        self.closesTLSListener = closesTLSListener
        self.logPhase = logPhase
    }
}
