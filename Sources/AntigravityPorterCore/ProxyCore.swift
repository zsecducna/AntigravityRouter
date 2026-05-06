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
        if Self.antigravityInferenceHosts.contains(normalizedHost) {
            return path.contains(":generateContent")
                || path.contains(":streamGenerateContent") ? .intercept : .blindTunnel
        }
        return .blindTunnel
    }

    private static let antigravityInferenceHosts: Set<String> = [
        "cloudcode-pa.googleapis.com",
        "daily-cloudcode-pa.googleapis.com",
        "127.0.0.1",
        "localhost"
    ]
}

public enum ConnectTargetPolicyDecision: Equatable, Sendable {
    case targetInference
    case blindTunnel
    case reject
}

public struct ConnectTargetPolicy: Equatable, Sendable {
    public static let `default` = ConnectTargetPolicy()

    public init() {}

    public func decision(for host: String, port: Int) -> ConnectTargetPolicyDecision {
        guard port == 443 else { return .reject }
        let normalizedHost = normalize(host)
        if Self.excludedHosts.contains(normalizedHost) {
            return .blindTunnel
        }
        if Self.targetInferenceHosts.contains(normalizedHost) {
            return .targetInference
        }
        return .blindTunnel
    }

    private func normalize(_ host: String) -> String {
        host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private static let targetInferenceHosts: Set<String> = [
        "cloudcode-pa.googleapis.com",
        "daily-cloudcode-pa.googleapis.com",
        "127.0.0.1",
        "localhost"
    ]

    private static let excludedHosts: Set<String> = [
        "oauth2.googleapis.com",
        "accounts.google.com",
        "www.googleapis.com",
        "cheaprouter.uk"
    ]
}

public enum GoogleUpstreamHostPolicy {
    public static func host(for originalHost: String) -> String {
        normalize(originalHost) == "cloudcode-pa.googleapis.com"
            ? "daily-cloudcode-pa.googleapis.com"
            : originalHost
    }

    private static func normalize(_ host: String) -> String {
        host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
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

public enum TLSClientHelloParser {
    public static func serverName(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5,
              bytes[0] == 0x16,
              bytes[1] == 0x03
        else { return nil }

        let recordLength = Int(bytes[3]) << 8 | Int(bytes[4])
        guard bytes.count >= min(recordLength + 5, bytes.count),
              bytes.count >= 9,
              bytes[5] == 0x01
        else { return nil }

        var index = 9
        guard bytes.count >= index + 2 + 32 else { return nil }
        index += 2 + 32

        guard bytes.count >= index + 1 else { return nil }
        let sessionIDLength = Int(bytes[index])
        index += 1 + sessionIDLength

        guard bytes.count >= index + 2 else { return nil }
        let cipherSuitesLength = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        index += 2 + cipherSuitesLength

        guard bytes.count >= index + 1 else { return nil }
        let compressionMethodsLength = Int(bytes[index])
        index += 1 + compressionMethodsLength

        guard bytes.count >= index + 2 else { return nil }
        let extensionsLength = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        index += 2
        let extensionsEnd = index + extensionsLength
        guard bytes.count >= extensionsEnd else { return nil }

        while index + 4 <= extensionsEnd {
            let type = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            index += 4
            guard index + length <= extensionsEnd else { return nil }
            if type == 0 {
                return serverName(fromSNIExtension: bytes[index..<index + length])
            }
            index += length
        }
        return nil
    }

    private static func serverName(fromSNIExtension slice: ArraySlice<UInt8>) -> String? {
        let bytes = Array(slice)
        guard bytes.count >= 5 else { return nil }
        let listLength = Int(bytes[0]) << 8 | Int(bytes[1])
        guard bytes.count >= 2 + listLength else { return nil }
        var index = 2
        let end = 2 + listLength
        while index + 3 <= end {
            let nameType = bytes[index]
            let nameLength = Int(bytes[index + 1]) << 8 | Int(bytes[index + 2])
            index += 3
            guard index + nameLength <= end else { return nil }
            if nameType == 0 {
                let name = String(decoding: bytes[index..<index + nameLength], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return name.isEmpty ? nil : name
            }
            index += nameLength
        }
        return nil
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
    case invalidChunkedBody(String)
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
        if headers["transfer-encoding"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "chunked" }) == true {
            body = try decodeChunkedBody(Data(rawBody)).body
        } else if let contentLength = headers["content-length"] {
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

    public static func decodeChunkedBody(_ data: Data) throws -> (body: Data, consumedBytes: Int) {
        let bytes = [UInt8](data)
        var index = 0
        var decoded = Data()

        while true {
            guard let lineEnd = crlfIndex(in: bytes, startingAt: index) else {
                throw HTTPRequestParseError.incomplete
            }
            guard let line = String(bytes: bytes[index..<lineEnd], encoding: .utf8) else {
                throw HTTPRequestParseError.invalidChunkedBody("chunk-size-not-utf8")
            }
            let sizeText = line
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !sizeText.isEmpty, let size = Int(sizeText, radix: 16), size >= 0 else {
                throw HTTPRequestParseError.invalidChunkedBody("invalid-chunk-size")
            }

            index = lineEnd + 2
            if size == 0 {
                guard let trailersEnd = chunkTrailersEnd(in: bytes, startingAt: index) else {
                    throw HTTPRequestParseError.incomplete
                }
                return (decoded, trailersEnd)
            }

            guard bytes.count >= index + size + 2 else {
                throw HTTPRequestParseError.incomplete
            }
            decoded.append(contentsOf: bytes[index..<index + size])
            index += size
            guard bytes[index] == 13, bytes[index + 1] == 10 else {
                throw HTTPRequestParseError.invalidChunkedBody("missing-chunk-terminator")
            }
            index += 2
        }
    }

    private static func crlfIndex(in bytes: [UInt8], startingAt start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10 {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func chunkTrailersEnd(in bytes: [UInt8], startingAt start: Int) -> Int? {
        guard bytes.count >= start + 2 else { return nil }
        if bytes[start] == 13, bytes[start + 1] == 10 {
            return start + 2
        }
        var index = start
        while index + 3 < bytes.count {
            if bytes[index] == 13,
               bytes[index + 1] == 10,
               bytes[index + 2] == 13,
               bytes[index + 3] == 10 {
                return index + 4
            }
            index += 1
        }
        return nil
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
