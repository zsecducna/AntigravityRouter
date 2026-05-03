import Foundation

public struct CaptureTiming: Equatable, Sendable {
    public var startedAt: Date
    public var durationMS: Int

    public init(startedAt: Date, durationMS: Int) {
        self.startedAt = startedAt
        self.durationMS = durationMS
    }
}

public struct CapturedExchange: Equatable, Sendable {
    public var id: String
    public var host: String
    public var path: String
    public var requestHeaders: [String: String]
    public var requestBody: Data
    public var responseStatus: Int
    public var responseHeaders: [String: String]
    public var responseBody: Data
    public var timing: CaptureTiming

    public init(
        id: String,
        host: String,
        path: String,
        requestHeaders: [String: String],
        requestBody: Data,
        responseStatus: Int,
        responseHeaders: [String: String],
        responseBody: Data,
        timing: CaptureTiming
    ) {
        self.id = id
        self.host = host
        self.path = path
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.responseStatus = responseStatus
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.timing = timing
    }
}

public enum CaptureSanitizerError: Error, Equatable, Sendable {
    case invalidJSON
}

public struct CaptureSanitizer: Sendable {
    private let secretHeaders = Set(["authorization", "x-goog-api-key", "cookie", "set-cookie", "x-api-key"])
    private let secretJSONKeys = Set(["access_token", "refresh_token", "id_token", "api_key", "authorization"])

    public init() {}

    public func sanitize(_ capture: CapturedExchange) throws -> CapturedExchange {
        var sanitized = capture
        sanitized.requestHeaders = redactHeaders(capture.requestHeaders)
        sanitized.responseHeaders = redactHeaders(capture.responseHeaders)
        sanitized.requestBody = try sanitizeJSONBody(capture.requestBody)
        sanitized.responseBody = try sanitizeJSONBody(capture.responseBody)
        return sanitized
    }

    private func redactHeaders(_ headers: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { key, value in
            (key, secretHeaders.contains(key.lowercased()) ? "<redacted>" : value)
        })
    }

    private func sanitizeJSONBody(_ body: Data) throws -> Data {
        guard !body.isEmpty else { return body }
        guard JSONSerialization.isValidJSONObject([:]),
              let object = try? JSONSerialization.jsonObject(with: body)
        else { return body }
        let redacted = redactJSON(object)
        guard JSONSerialization.isValidJSONObject(redacted) else { throw CaptureSanitizerError.invalidJSON }
        return try JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys])
    }

    private func redactJSON(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.mapValues { $0 }.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = secretJSONKeys.contains(pair.key.lowercased()) ? "<redacted>" : redactJSON(pair.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(redactJSON)
        }
        return value
    }
}

public struct CaptureManifestEntry: Equatable, Sendable {
    public var captureID: String
    public var host: String
    public var path: String
    public var sanitized: Bool
    public var durationMS: Int

    public init(captureID: String, host: String, path: String, sanitized: Bool, durationMS: Int) {
        self.captureID = captureID
        self.host = host
        self.path = path
        self.sanitized = sanitized
        self.durationMS = durationMS
    }
}

public struct CaptureManifest: Equatable, Sendable {
    public var id: String
    public var generatedAt: Date
    public var entries: [CaptureManifestEntry]

    public init(id: String, generatedAt: Date, entries: [CaptureManifestEntry]) {
        self.id = id
        self.generatedAt = generatedAt
        self.entries = entries
    }

    public var isExportable: Bool {
        blockingCaptureIDs.isEmpty
    }

    public var blockingCaptureIDs: [String] {
        entries.filter { !$0.sanitized }.map(\.captureID)
    }
}

public struct CapturePipeline: Sendable {
    public init() {}
}
