import AntigravityPorterCore
import Combine
import Darwin
import Foundation
import Network
#if canImport(Security)
import Security
#endif

final class PorterRuntimeController: ObservableObject, @unchecked Sendable {
    @Published private(set) var status = PorterAppStatus()

    private static let maximumRecentLogEntries = 1000
    private static let maximumDisplayedLogLineBytes = 16 * 1024
    private static let maximumLogFileBytes: UInt64 = 5 * 1024 * 1024
    private var server: NWProxyServer?
    private var activeProxyHost = "127.0.0.1"
    private var activeProxyPort = 8877
    private var providerReachabilityTask: URLSessionDataTask?
    private var providerReachabilityGeneration = 0
    private let providerReachabilityLock = NSLock()
    private let settingsStore = UserDefaultsSettingsStore()
    private let keychainStore = SecurityKeychainStore()
    private let certificateStore: any KeychainStoring
    private let logDirectory: URL
    private lazy var certificateAuthority = CertificateAuthority(keychain: certificateStore)

    init(logDirectory: URL = PorterRuntimeController.defaultLogDirectory, certificateStore: (any KeychainStoring)? = nil) {
        self.logDirectory = logDirectory
        self.certificateStore = certificateStore ?? Self.certificateAuthorityStore()
    }

    func setProxyEnabled(_ enabled: Bool, settings: PorterSettings) {
        if enabled {
            start(settings: settings)
        } else {
            stop()
        }
    }

    func waitUntilReady(
        settings: PorterSettings,
        timeout: TimeInterval,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        start(settings: settings)
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            if status.proxyEnabled {
                completion(.success(()))
                return
            }
            if let lastError = status.lastError {
                completion(.failure(PorterRuntimeError.startFailed(lastError)))
                return
            }
            guard Date() < deadline else {
                completion(.failure(PorterRuntimeError.startTimedOut(timeout)))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                poll()
            }
        }

        poll()
    }

    func start(settings: PorterSettings) {
        refreshProviderReachability(settings: settings)
        if let server {
            guard activeProxyHost != settings.localProxyHost || activeProxyPort != settings.localProxyPort else {
                return
            }
            server.stop()
            self.server = nil
            updateStatus { status in
                status.proxyEnabled = false
            }
            appendRuntimeLog("listener restarting \(settings.localProxyHost):\(settings.localProxyPort)")
        }

        do {
            try prepareRuntimeCertificateBundle()
            let server = NWProxyServer(
                host: settings.localProxyHost,
                port: settings.localProxyPort,
                settingsStore: settingsStore,
                keychainStore: keychainStore,
                certificateAuthority: certificateAuthority,
                eventSink: { [weak self] event in self?.handle(event) },
                pacScriptProvider: { [weak self] in
                    PACScript.generate(
                        proxyHost: self?.activeProxyHost ?? PorterSettings.defaultProxyHost,
                        proxyPort: self?.activeProxyPort ?? PorterSettings.defaultProxyPort
                    )
                }
            )
            try server.start()
            self.server = server
            activeProxyHost = settings.localProxyHost
            activeProxyPort = settings.localProxyPort
            handleListenerReady(port: settings.localProxyPort)
        } catch {
            server?.stop()
            server = nil
            updateStatus { status in
                status.proxyEnabled = false
                status.lastError = String(describing: error)
            }
            appendRuntimeLog("proxy enable failed: \(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        updateStatus { status in
            status.proxyEnabled = false
        }
        appendRuntimeLog("proxy OFF")
    }

    func refreshProviderReachability(settings: PorterSettings) {
        let generation = nextProviderReachabilityGeneration()
        providerReachabilityTask?.cancel()
        updateStatus { status in
            status.providerReachability = .checking
        }

        var request = URLRequest(url: settings.cheapRouterBaseURL)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5

        let configuration = URLSessionCheapRouterTransport.proxyBypassingConfiguration()
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { [weak self] _, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                return
            }
            guard self?.isCurrentProviderReachabilityGeneration(generation) == true else {
                return
            }
            if let response = response as? HTTPURLResponse, (100..<600).contains(response.statusCode) {
                self?.updateStatus { status in
                    status.providerReachability = .reachable
                }
                return
            }
            let message = error?.localizedDescription ?? "invalid HTTP response"
            self?.updateStatus { status in
                status.providerReachability = .unreachable(message)
            }
        }
        providerReachabilityTask = task
        task.resume()
    }

    private func nextProviderReachabilityGeneration() -> Int {
        providerReachabilityLock.lock()
        defer { providerReachabilityLock.unlock() }
        providerReachabilityGeneration += 1
        return providerReachabilityGeneration
    }

    private func isCurrentProviderReachabilityGeneration(_ generation: Int) -> Bool {
        providerReachabilityLock.lock()
        defer { providerReachabilityLock.unlock() }
        return providerReachabilityGeneration == generation
    }

    func truncateLogs() {
        for file in logFiles {
            do {
                try hardenLogDirectory()
                try Data().write(to: file, options: .atomic)
                try hardenLogFile(file)
            } catch {
                print("truncate log file failed: \(file.path): \(error)")
                fflush(stdout)
            }
        }
        updateStatus { status in
            status.recentLogLines.removeAll()
        }
    }

    func exportLogs(to destination: URL) throws {
        try hardenLogDirectory()
        let sections = logFiles.map { file in
            let data = FileManager.default.contents(atPath: file.path) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return "===== \(file.lastPathComponent) =====\n\(text)"
        }
        try sections.joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func handleListenerReady(port: Int) {
        appendRuntimeLog("listener ready \(activeProxyHost):\(port)")
        updateStatus { status in
            status.proxyEnabled = true
            status.lastError = nil
        }
        appendRuntimeLog("local proxy listener ON \(activeProxyHost):\(port)")
    }

    private func handle(_ event: ProxyRuntimeEvent) {
        switch event {
        case let .connect(line, targetInference):
            updateStatus { status in
                status.totalRequests += 1
                if targetInference {
                    status.targetInferenceConnects += 1
                } else {
                    status.blindTunnelConnects += 1
                }
            }
            appendRuntimeLog(line)
        case let .routed(line):
            updateStatus { status in
                status.routedRequests += 1
            }
            appendRuntimeLog(line)
        case let .directModel(line):
            updateStatus { status in
                status.googleDirectRequests += 1
            }
            appendRuntimeLog(line)
        case let .direct(line):
            appendRuntimeLog(line)
        case let .log(line):
            appendRuntimeLog(line)
        case let .failed(message):
            updateStatus { status in
                status.lastError = message
            }
            appendRuntimeLog(message)
        }
    }

    private func appendRuntimeLog(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let rendered = "\(timestamp) \(line)"
        let displayed = Self.displayLine(for: rendered)
        print(displayed)
        fflush(stdout)
        appendRuntimeLogFile(rendered)
        updateStatus { status in
            status.recentLogLines.append(displayed)
            if status.recentLogLines.count > Self.maximumRecentLogEntries {
                status.recentLogLines.removeFirst(status.recentLogLines.count - Self.maximumRecentLogEntries)
            }
        }
    }

    private static func displayLine(for line: String) -> String {
        let bytes = Data(line.utf8)
        guard bytes.count > maximumDisplayedLogLineBytes else { return line }
        let prefix = bytes.prefix(maximumDisplayedLogLineBytes)
        let text = String(decoding: prefix, as: UTF8.self)
        return "\(text)\n<display truncated bytes=\(bytes.count - prefix.count); full raw stored in raw-http.log/runtime.log>"
    }

    private func appendRuntimeLogFile(_ line: String) {
        let directory = logDirectory
        let file = directory.appendingPathComponent("runtime.log")
        do {
            try hardenLogDirectory()
            try rotateLogIfNeeded(file)
            let data = Data((line + "\n").utf8)
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: file, options: .atomic)
            }
            try hardenLogFile(file)
        } catch {
            print("runtime log file failed: \(error)")
            fflush(stdout)
        }
        if line.contains("===== ") {
            appendRawHTTPLogFile(line)
        }
    }

    private func appendRawHTTPLogFile(_ line: String) {
        let directory = logDirectory
        let file = directory.appendingPathComponent("raw-http.log")
        do {
            try hardenLogDirectory()
            try rotateLogIfNeeded(file)
            let data = Data((line + "\n").utf8)
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: file, options: .atomic)
            }
            try hardenLogFile(file)
        } catch {
            print("raw HTTP log file failed: \(error)")
            fflush(stdout)
        }
    }

    private func rotateLogIfNeeded(_ file: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return }
        let size = (try manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= Self.maximumLogFileBytes else { return }
        let rotated = file.deletingPathExtension().appendingPathExtension("\(file.pathExtension).1")
        if manager.fileExists(atPath: rotated.path) {
            try manager.removeItem(at: rotated)
        }
        try manager.moveItem(at: file, to: rotated)
        try hardenLogFile(rotated)
    }

    private func hardenLogDirectory() throws {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logDirectory.path)
    }

    private func hardenLogFile(_ file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func updateStatus(_ body: @escaping @Sendable (inout PorterAppStatus) -> Void) {
        DispatchQueue.main.async {
            body(&self.status)
        }
    }

    private static var defaultLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AntigravityPorter", isDirectory: true)
    }

    private var logFiles: [URL] {
        [
            logDirectory.appendingPathComponent("runtime.log"),
            logDirectory.appendingPathComponent("raw-http.log")
        ]
    }

    private static func certificateAuthorityStore() -> any KeychainStoring {
        MigratingKeychainStore(
            primary: FileKeychainStore(directory: certificateAuthorityDirectory()),
            fallback: SecurityKeychainStore(service: "uk.cheaprouter.AntigravityPorter.ca")
        )
    }

    private static func certificateAuthorityDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AntigravityPorter/CertificateAuthority", isDirectory: true)
    }

    private func prepareRuntimeCertificateBundle() throws {
        let caDER = try certificateAuthority.exportSigningIdentityDER()
        let appDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AntigravityPorter", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDirectory.path)

        let certificateURL = appDirectory.appendingPathComponent("AntigravityRouter Local CA.pem")
        let base64 = caDER.base64EncodedString(options: [.lineLength64Characters])
        let pem = "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
        try Data(pem.utf8).write(to: certificateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certificateURL.path)
    }
}

enum ProxyRuntimeEvent: Sendable {
    case connect(String, targetInference: Bool)
    case routed(String)
    case directModel(String)
    case direct(String)
    case log(String)
    case failed(String)
}

final class FileKeychainStore: KeychainStoring, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    func data(for key: KeychainSecretKey) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let file = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        try hardenStoragePermissions(file: file)
        return try Data(contentsOf: file)
    }

    func setData(_ data: Data, for key: KeychainSecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = fileURL(for: key)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func delete(_ key: KeychainSecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        let file = fileURL(for: key)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func fileURL(for key: KeychainSecretKey) -> URL {
        directory.appendingPathComponent("\(key.rawValue).bin", isDirectory: false)
    }

    private func hardenStoragePermissions(file: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        if manager.fileExists(atPath: file.path) {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}

private final class GoogleUpstreamResolver: @unchecked Sendable {
    private struct DNSResponse: Decodable {
        struct Answer: Decodable {
            var type: Int
            var data: String
        }

        var Answer: [Answer]?
    }

    private let lock = NSLock()
    private let session: URLSession
    private var cache: [String: (ip: String, expiresAt: Date)] = [:]

    init() {
        let configuration = URLSessionCheapRouterTransport.proxyBypassingConfiguration()
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        session = URLSession(configuration: configuration)
    }

    func resolveIPv4(host: String) throws -> String {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        if let cached = cache[normalized], cached.expiresAt > Date() {
            lock.unlock()
            return cached.ip
        }
        lock.unlock()

        var components = URLComponents(string: "https://dns.google/resolve")
        components?.queryItems = [
            URLQueryItem(name: "name", value: normalized),
            URLQueryItem(name: "type", value: "A")
        ]
        guard let url = components?.url else {
            throw PorterRuntimeError.invalidURL("https://dns.google/resolve?name=\(normalized)&type=A")
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let raw = try performDNSRequest(request)
        let decoded = try JSONDecoder().decode(DNSResponse.self, from: raw.body)
        guard let ip = decoded.Answer?.first(where: { $0.type == 1 && Self.isIPv4Address($0.data) })?.data else {
            throw PorterRuntimeError.socketFailed("resolve upstream \(normalized): no A record")
        }

        lock.lock()
        cache[normalized] = (ip: ip, expiresAt: Date().addingTimeInterval(300))
        lock.unlock()
        return ip
    }

    private func performDNSRequest(_ request: URLRequest) throws -> (statusCode: Int, body: Data) {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var result: Result<(Int, Data), Error>?
        }
        let box = Box()
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(error)
                return
            }
            guard let response = response as? HTTPURLResponse else {
                box.result = .failure(PorterRuntimeError.invalidHTTPResponse)
                return
            }
            guard (200..<300).contains(response.statusCode) else {
                box.result = .failure(PorterRuntimeError.socketFailed("dns.google status \(response.statusCode)"))
                return
            }
            box.result = .success((response.statusCode, data ?? Data()))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            task.cancel()
            throw PorterRuntimeError.upstreamTimedOut
        }
        let value = try box.result?.get() ?? { throw PorterRuntimeError.invalidHTTPResponse }()
        return (statusCode: value.0, body: value.1)
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, value, &addr) == 1
    }
}

private enum TunnelKind: String {
    case targetInference = "target"
    case blindTunnel = "blind"
}

private enum TunnelDirection {
    case clientToUpstream
    case upstreamToClient
}

private final class TunnelMetrics: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let kind: TunnelKind
    private let startedAt = Date()
    private let lock = NSLock()
    private var clientToUpstreamBytes = 0
    private var upstreamToClientBytes = 0
    private var closed = false

    init(host: String, port: Int, kind: TunnelKind) {
        self.host = host
        self.port = port
        self.kind = kind
    }

    func record(byteCount: Int, direction: TunnelDirection) {
        lock.lock()
        defer { lock.unlock() }
        switch direction {
        case .clientToUpstream:
            clientToUpstreamBytes += byteCount
        case .upstreamToClient:
            upstreamToClientBytes += byteCount
        }
    }

    func finishSummary() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        closed = true
        let durationMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        return "tunnel closed \(host):\(port) kind=\(kind.rawValue) up_bytes=\(clientToUpstreamBytes) down_bytes=\(upstreamToClientBytes) duration_ms=\(durationMS)"
    }
}

extension PorterAction {
    var logName: String {
        switch self {
        case .generateContent: "generateContent"
        case .streamGenerateContent: "streamGenerateContent"
        case .countTokens: "countTokens"
        case let .unknown(value): value
        }
    }
}

enum PorterRuntimeError: Error, Equatable, LocalizedError {
    case invalidPort(Int)
    case invalidHost(String)
    case invalidURL(String)
    case socketFailed(String)
    case tlsFailed(String)
    case securityUnavailable
    case connectionClosed
    case upstreamTimedOut
    case invalidHTTPResponse
    case startFailed(String)
    case startTimedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .invalidPort(port):
            "invalid port \(port)"
        case let .invalidHost(host):
            "invalid host \(host)"
        case let .invalidURL(url):
            "invalid URL \(url)"
        case let .socketFailed(message):
            message
        case let .tlsFailed(message):
            "TLS failed: \(message)"
        case .securityUnavailable:
            "Security framework is unavailable"
        case .connectionClosed:
            "connection closed"
        case .upstreamTimedOut:
            "upstream timed out"
        case .invalidHTTPResponse:
            "invalid HTTP response"
        case let .startFailed(message):
            message
        case let .startTimedOut(timeout):
            "listener not ready after \(String(format: "%.1f", timeout))s"
        }
    }
}
