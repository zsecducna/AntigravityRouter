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

public struct HTTPRequestEnvelope: Equatable, Sendable {
    public var method: String
    public var path: String
    public var httpVersion: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, httpVersion: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
    }

    public func removingProxyHeaders() -> HTTPRequestEnvelope {
        HTTPRequestEnvelope(
            method: method,
            path: path,
            httpVersion: httpVersion,
            headers: headers.filter { !$0.key.lowercased().hasPrefix("proxy-") },
            body: body
        )
    }
}

public enum HTTPRequestParseError: Error, Equatable, Sendable {
    case incomplete
    case malformedRequestLine(String)
    case invalidContentLength(String)
}

public enum HTTPRequestParser {
    public static func parse(_ data: Data) throws -> HTTPRequestEnvelope {
        let delimiterRange: Range<Data.Index>
        if let range = data.range(of: Data("\r\n\r\n".utf8)) {
            delimiterRange = range
        } else if let range = data.range(of: Data("\n\n".utf8)) {
            delimiterRange = range
        } else {
            throw HTTPRequestParseError.incomplete
        }

        guard let headerText = String(data: data[..<delimiterRange.lowerBound], encoding: .utf8) else {
            throw HTTPRequestParseError.incomplete
        }
        let lines = headerText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard let requestLine = lines.first else {
            throw HTTPRequestParseError.incomplete
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else {
            throw HTTPRequestParseError.malformedRequestLine(requestLine)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let rawBody = data[delimiterRange.upperBound...]
        let body: Data
        if let contentLength = headers["content-length"] {
            guard let expectedLength = Int(contentLength), expectedLength >= 0 else {
                throw HTTPRequestParseError.invalidContentLength(contentLength)
            }
            guard rawBody.count >= expectedLength else {
                throw HTTPRequestParseError.incomplete
            }
            body = Data(rawBody.prefix(expectedLength))
        } else {
            body = Data(rawBody)
        }

        return HTTPRequestEnvelope(method: parts[0], path: parts[1], httpVersion: parts[2], headers: headers, body: body)
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

public enum ProxyPlanningFailure: Equatable, Sendable {
    case modelExtractionFailed
    case routingFailed(RoutingFailureReason)
    case translationFailed(TranslatorFailureReason)
}

public enum PlannedProxyAction: Equatable, Sendable {
    case forwardToGoogle(request: HTTPRequestEnvelope, metadata: ModelRequestMetadata)
    case routeToCheapRouter(payload: CheapRouterRequestPayload, metadata: ModelRequestMetadata)
    case failClosed(reason: ProxyPlanningFailure)
}

public struct ProxyRequestPlanner: Sendable {
    public var routingEngine: RoutingEngine
    public var translator: Translator

    public init(routingEngine: RoutingEngine, translator: Translator = Translator()) {
        self.routingEngine = routingEngine
        self.translator = translator
    }

    public func plan(host: String, request: HTTPRequestEnvelope) -> PlannedProxyAction {
        let metadata: ModelRequestMetadata
        do {
            metadata = try ModelExtractor.extract(host: host, path: request.path, body: request.body)
        } catch {
            return .failClosed(reason: .modelExtractionFailed)
        }

        switch routingEngine.decision(for: metadata) {
        case .googleDirect:
            return .forwardToGoogle(request: request.removingProxyHeaders(), metadata: metadata)
        case let .cheapRouter(endpoint):
            switch translator.translate(metadata: metadata, body: request.body, endpoint: endpoint) {
            case let .success(payload):
                return .routeToCheapRouter(payload: payload, metadata: metadata)
            case let .failClosed(reason):
                return .failClosed(reason: .translationFailed(reason))
            }
        case let .failClosed(reason):
            return .failClosed(reason: .routingFailed(reason))
        }
    }
}
