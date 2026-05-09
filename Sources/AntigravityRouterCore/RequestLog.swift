import Foundation

public final class RequestLog {
    public struct Event: Equatable {
        public let timestamp: Date
        public let method: String
        public let url: URL
        public let headers: [String: String]
        public let bodyPreview: String
    }

    private let capacity: Int
    private var events: [Event] = []

    public private(set) var totalRecordedCount = 0

    public init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    public func record(method: String, url: URL, headers: [String: String], bodyPreview: String) {
        totalRecordedCount += 1

        let event = Event(
            timestamp: Date(),
            method: method,
            url: Self.sanitizedURL(url),
            headers: Self.sanitizedHeaders(headers),
            bodyPreview: Self.sanitizedBodyPreview(bodyPreview)
        )

        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    public func snapshot() -> [Event] {
        events
    }

    private static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { name, value in
            (name, isSensitiveHeader(name) ? "[REDACTED]" : value)
        })
    }

    private static func sanitizedURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems
        else {
            return url
        }

        components.queryItems = queryItems.map { item in
            if isSensitiveQueryName(item.name) {
                return URLQueryItem(name: item.name, value: "[REDACTED]")
            }
            return item
        }

        return components.url ?? url
    }

    private static func sanitizedBodyPreview(_ bodyPreview: String) -> String {
        let lowered = bodyPreview.lowercased()
        let sensitiveNeedles = [
            "access_token",
            "api_key",
            "authorization",
            "cookie",
            "prompt",
            "refresh_token",
            "secret",
            "token"
        ]

        guard sensitiveNeedles.contains(where: lowered.contains) else {
            return bodyPreview
        }

        return "[REDACTED]"
    }

    private static func isSensitiveHeader(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized == "authorization"
            || normalized == "cookie"
            || normalized == "set-cookie"
            || normalized == "x-goog-api-key"
            || normalized == "x-api-key"
            || normalized.contains("token")
            || normalized.contains("secret")
    }

    private static func isSensitiveQueryName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized == "key"
            || normalized == "api_key"
            || normalized == "access_token"
            || normalized == "token"
            || normalized.contains("secret")
    }
}
