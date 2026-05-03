import Foundation

public enum HostPolicyDecision: Equatable, Sendable {
    case intercept
    case blindTunnel
}

public struct HostPolicy: Equatable, Sendable {
    public static let `default` = HostPolicy()

    public init() {}

    public func decision(for host: String, port: Int, path: String?) -> HostPolicyDecision {
        guard port == 443 else { return .blindTunnel }
        let normalizedHost = host.lowercased()
        if ["oauth2.googleapis.com", "accounts.google.com", "www.googleapis.com", "cheaprouter.uk"].contains(normalizedHost) {
            return .blindTunnel
        }
        guard let path else { return .blindTunnel }
        if ["cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com", "sandbox-cloudcode-pa.googleapis.com"].contains(normalizedHost) {
            return path.contains(":generateContent")
                || path.contains(":streamGenerateContent")
                || path.contains(":countTokens") ? .intercept : .blindTunnel
        }
        if normalizedHost == "generativelanguage.googleapis.com" {
            return path.contains(":generateContent")
                || path.contains(":streamGenerateContent")
                || path.contains(":countTokens") ? .intercept : .blindTunnel
        }
        return .blindTunnel
    }
}

public enum ProxyALPN: String, Equatable, Sendable {
    case http1_1 = "http/1.1"
    case h2
    case unknown
}

public enum ProxyGateFailure: Equatable, Sendable {
    case unsupportedALPN(ProxyALPN)
}

public enum ProxyProtocolDecision: Equatable, Sendable {
    case terminateTLS
    case blindTunnel
    case failClosed(reason: ProxyGateFailure)
}

public enum ProxyProtocolGate {
    public static func decision(for alpn: ProxyALPN, hostDecision: HostPolicyDecision) -> ProxyProtocolDecision {
        guard hostDecision == .intercept else { return .blindTunnel }
        return alpn == .http1_1 ? .terminateTLS : .failClosed(reason: .unsupportedALPN(alpn))
    }
}

public struct ConnectRequest: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var httpVersion: String
    public var headers: [String: String]
}

public enum ConnectParseError: Error, Equatable, Sendable {
    case incomplete
    case malformedRequestLine(String)
    case unsupportedMethod(String)
    case invalidAuthority(String)
    case invalidPort(String)
}

public enum ConnectRequestParser {
    public static func parse(_ data: Data) throws -> ConnectRequest {
        guard var text = String(data: data, encoding: .utf8) else {
            throw ConnectParseError.incomplete
        }
        text = text
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
        guard text.contains("\n\n") || text.contains("\n") else {
            throw ConnectParseError.incomplete
        }
        let lines = text.components(separatedBy: "\n")
        let requestLine = lines[0]
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else { throw ConnectParseError.malformedRequestLine(requestLine) }
        guard parts[0] == "CONNECT" else { throw ConnectParseError.unsupportedMethod(parts[0]) }

        let authority = parts[1]
        let authorityParts = authority.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard authorityParts.count == 2, !authorityParts[0].isEmpty, !authorityParts[1].isEmpty else {
            throw ConnectParseError.invalidAuthority(authority)
        }
        guard let port = Int(authorityParts[1]) else {
            throw ConnectParseError.invalidPort(authorityParts[1])
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return ConnectRequest(host: authorityParts[0], port: port, httpVersion: parts[2], headers: headers)
    }
}

public struct ProxyCore: Sendable {
    public init() {}
}
