import Foundation

public struct CaptureTiming: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var durationMS: Int

    public init(startedAt: Date, durationMS: Int) {
        self.startedAt = startedAt
        self.durationMS = durationMS
    }
}

public struct CapturedExchange: Codable, Equatable, Sendable {
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

public struct CaptureManifestEntry: Codable, Equatable, Sendable {
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

public struct CaptureManifest: Codable, Equatable, Sendable {
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

public struct CaptureFixturePack: Equatable, Sendable {
    public var manifest: CaptureManifest
    public var captures: [CapturedExchange]

    public init(manifest: CaptureManifest, captures: [CapturedExchange]) {
        self.manifest = manifest
        self.captures = captures
    }
}

public enum CaptureFixtureStoreError: Error, Equatable, Sendable {
    case unsafeManifest([String])
    case missingCapture(String)
}

public struct CaptureFixtureStore {
    private let fileManager: FileManager
    private let sanitizer: CaptureSanitizer

    public init(fileManager: FileManager = .default, sanitizer: CaptureSanitizer = CaptureSanitizer()) {
        self.fileManager = fileManager
        self.sanitizer = sanitizer
    }

    @discardableResult
    public func writeSanitizedPack(
        captures: [CapturedExchange],
        to directory: URL,
        manifestID: String,
        generatedAt: Date = Date()
    ) throws -> CaptureManifest {
        try fileManager.createDirectory(at: capturesDirectory(in: directory), withIntermediateDirectories: true)

        var entries: [CaptureManifestEntry] = []
        for capture in captures {
            let sanitized = try sanitizer.sanitize(capture)
            let data = try JSONEncoder.captureFixtureEncoder.encode(sanitized)
            try data.write(to: captureURL(for: capture.id, in: directory), options: [.atomic])
            entries.append(.init(
                captureID: capture.id,
                host: capture.host,
                path: capture.path,
                sanitized: true,
                durationMS: capture.timing.durationMS
            ))
        }

        let manifest = CaptureManifest(id: manifestID, generatedAt: generatedAt, entries: entries)
        guard manifest.isExportable else {
            throw CaptureFixtureStoreError.unsafeManifest(manifest.blockingCaptureIDs)
        }
        let manifestData = try JSONEncoder.captureFixtureEncoder.encode(manifest)
        try manifestData.write(to: manifestURL(in: directory), options: [.atomic])
        return manifest
    }

    public func readPack(from directory: URL) throws -> CaptureFixturePack {
        let manifestData = try Data(contentsOf: manifestURL(in: directory))
        let manifest = try JSONDecoder.captureFixtureDecoder.decode(CaptureManifest.self, from: manifestData)
        guard manifest.isExportable else {
            throw CaptureFixtureStoreError.unsafeManifest(manifest.blockingCaptureIDs)
        }
        let captures = try manifest.entries.map { entry in
            let url = captureURL(for: entry.captureID, in: directory)
            guard fileManager.fileExists(atPath: url.path) else {
                throw CaptureFixtureStoreError.missingCapture(entry.captureID)
            }
            return try JSONDecoder.captureFixtureDecoder.decode(CapturedExchange.self, from: Data(contentsOf: url))
        }
        return CaptureFixturePack(manifest: manifest, captures: captures)
    }

    private func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    private func capturesDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("captures", isDirectory: true)
    }

    private func captureURL(for id: String, in directory: URL) -> URL {
        capturesDirectory(in: directory).appendingPathComponent(safeFileName(for: id)).appendingPathExtension("json")
    }

    private func safeFileName(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = id.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let name = String(scalars)
        return name.isEmpty ? "capture" : name
    }
}

public struct ReplayResult: Equatable, Sendable {
    public var captureID: String
    public var action: PlannedProxyAction

    public init(captureID: String, action: PlannedProxyAction) {
        self.captureID = captureID
        self.action = action
    }
}

public struct ReplayHarness: Sendable {
    private let planner: ProxyRequestPlanner

    public init(planner: ProxyRequestPlanner) {
        self.planner = planner
    }

    public func replay(_ capture: CapturedExchange) -> ReplayResult {
        let request = HTTPRequestEnvelope(
            method: "POST",
            path: capture.path,
            httpVersion: "HTTP/1.1",
            headers: capture.requestHeaders,
            body: capture.requestBody
        )
        return ReplayResult(captureID: capture.id, action: planner.plan(host: capture.host, request: request))
    }

    public func replay(_ pack: CaptureFixturePack) -> [ReplayResult] {
        pack.captures.map(replay)
    }
}

private extension JSONEncoder {
    static var captureFixtureEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var captureFixtureDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
