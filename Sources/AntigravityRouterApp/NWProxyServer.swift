import AntigravityRouterCore
import Darwin
import Foundation
import Network
#if canImport(Security)
import Security
#endif

final class NWProxyServer: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let settingsStore: UserDefaultsSettingsStore
    private let keychainStore: any KeychainStoring
    private let providerKeychainStoreFactory: @Sendable (String) -> any KeychainStoring
    private let certificateAuthority: CertificateAuthority
    private let eventSink: @Sendable (ProxyRuntimeEvent) -> Void
    private let pacScriptProvider: @Sendable () -> String
    private let networkQueue = DispatchQueue(label: "uk.cheaprouter.AntigravityRouter.network.events", attributes: .concurrent)
    private let stateLock = NSLock()
    private var listeners: [NWListener] = []
    private var activeConnections: [NWConnection] = []
    private var running = false
    private let cheapRouterSession: URLSession
    private let googleSession: URLSession

    private static let tlsPeekBytes = 8192
    private static let maximumInitialHeaderBytes = 65536
    private static let maximumHTTPRequestBytes = 4 * 1024 * 1024
    private static let connectHeaderTimeout: TimeInterval = 5
    private static let tlsReadTimeout: TimeInterval = 600
    private static let upstreamTimeout: TimeInterval = 600
    private static let pipeBufferSize = 65536
    private static let reverseProxyHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    var boundPort: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listeners.first?.port.map { Int($0.rawValue) } ?? port
    }

    static func classifyInitialBufferForTest(initial: Data, next: () -> Data?) -> InitialBufferClassification {
        var data = initial
        if data.first == 0x16 {
            while data.count < 6, let chunk = next() {
                data.append(chunk)
            }
            if data.count >= 6,
               data[data.startIndex] == 0x16,
               data[data.startIndex + 1] == 0x03,
               data[data.startIndex + 5] == 0x01 {
                return .directTLS(data)
            }
        }
        return .plain(data)
    }

    init(
        host: String,
        port: Int,
        settingsStore: UserDefaultsSettingsStore,
        keychainStore: any KeychainStoring,
        providerKeychainStoreFactory: (@Sendable (String) -> any KeychainStoring)? = nil,
        certificateAuthority: CertificateAuthority,
        eventSink: @escaping @Sendable (ProxyRuntimeEvent) -> Void,
        pacScriptProvider: @escaping @Sendable () -> String
    ) {
        self.host = host
        self.port = port
        self.settingsStore = settingsStore
        self.keychainStore = keychainStore
        self.providerKeychainStoreFactory = providerKeychainStoreFactory ?? { providerID in
            MigratingKeychainStore(
                primary: SecurityKeychainStore(service: Self.providerKeychainService(providerID: providerID, legacy: false)),
                fallback: SecurityKeychainStore(service: Self.providerKeychainService(providerID: providerID, legacy: true))
            )
        }
        self.certificateAuthority = certificateAuthority
        self.eventSink = eventSink
        self.pacScriptProvider = pacScriptProvider
        let configuration = URLSessionCheapRouterTransport.proxyBypassingConfiguration()
        configuration.timeoutIntervalForRequest = Self.upstreamTimeout
        configuration.timeoutIntervalForResource = Self.upstreamTimeout
        cheapRouterSession = URLSession(configuration: configuration)

        let googleConfiguration = URLSessionCheapRouterTransport.proxyBypassingConfiguration()
        googleConfiguration.timeoutIntervalForRequest = Self.upstreamTimeout
        googleConfiguration.timeoutIntervalForResource = Self.upstreamTimeout
        googleSession = URLSession(configuration: googleConfiguration)
    }

    func start() throws {
        guard (0...65535).contains(port) else {
            throw PorterRuntimeError.invalidPort(port)
        }

        stateLock.lock()
        guard listeners.isEmpty else {
            stateLock.unlock()
            return
        }
        running = true
        stateLock.unlock()

        do {
            var started: [NWListener] = []
            var listenerPort = port
            let listenHosts = ProxyListenerPlan.loopbackHosts(for: host)
            for listenHost in listenHosts {
                let listener = try makeListener(host: listenHost, port: listenerPort)
                started.append(listener)
                if listenerPort == 0, let rawPort = listener.port?.rawValue {
                    listenerPort = Int(rawPort)
                }
            }
            stateLock.lock()
            listeners = started
            stateLock.unlock()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        running = false
        let existingListeners = listeners
        let existingConnections = activeConnections
        listeners = []
        activeConnections = []
        stateLock.unlock()

        for listener in existingListeners {
            listener.cancel()
        }
        for connection in existingConnections {
            connection.cancel()
        }
    }

    private func makeListener(host: String, port: Int) throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listenerPort = NWEndpoint.Port(rawValue: UInt16(port))!
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: listenerPort)
        let listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        let failed = LockedBox<Error>()
        listener.newConnectionHandler = { [weak self] connection in
            guard let server = self else {
                connection.cancel()
                return
            }
            server.track(connection)
            server.runBlockingNetworkTask { [weak server] in
                server?.handleClient(connection)
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case let .failed(error):
                failed.value = PorterRuntimeError.socketFailed("listen \(host):\(port): \(error)")
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: networkQueue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw PorterRuntimeError.socketFailed("listen \(host):\(port): timed out")
        }
        if let error = failed.value {
            listener.cancel()
            throw error
        }
        return listener
    }

    private func track(_ connection: NWConnection) {
        stateLock.lock()
        activeConnections.append(connection)
        stateLock.unlock()
    }

    private func untrack(_ connection: NWConnection) {
        stateLock.lock()
        activeConnections.removeAll { $0 === connection }
        stateLock.unlock()
    }

    private func handleClient(_ client: NWConnection) {
        defer {
            client.cancel()
            untrack(client)
        }

        do {
            client.start(queue: networkQueue)
            try waitReady(client, timeout: Self.connectHeaderTimeout, phase: "client-ready")
            let initial = try receiveInitialBytes(client)
            let classification = try classifyInitialBytes(client: client, initial: initial)

            switch classification {
            case let .directTLS(tlsBytes):
                let targetHost = Self.directTLSHost(from: tlsBytes, fallbackListenHost: host)
                switch ConnectTargetPolicy.default.decision(for: targetHost, port: 443) {
                case .targetInference:
                    eventSink(.connect("DIRECT TLS \(targetHost):443 -> target Google API MITM", targetInference: true))
                    try handleMITM(client: client, host: targetHost, initialTLSBytes: tlsBytes, sendConnectResponse: false)
                case .blindTunnel:
                    eventSink(.connect("DIRECT TLS \(targetHost):443 -> blind tunnel", targetInference: false))
                    try handleBlindTunnel(client: client, host: targetHost, port: 443, initialBytes: tlsBytes, sendConnectResponse: false)
                case .reject:
                    eventSink(.log("direct TLS rejected unknown SNI \(targetHost.isEmpty ? "<missing>" : targetHost)"))
                }
                return

            case let .plain(plain):
                if let method = pacRequestMethod(from: plain.header) {
                    let response = ProxyWireProtocol.pacResponse(method: method, script: pacScriptProvider())
                    try sendAll(response, on: client, timeout: Self.connectHeaderTimeout, phase: "pac-send")
                    eventSink(.log("served PAC \(host):\(port)"))
                    return
                }

                let request = try ConnectRequestParser.parse(plain.header)
                switch ConnectTargetPolicy.default.decision(for: request.host, port: request.port) {
                case .targetInference:
                    eventSink(.connect("CONNECT \(request.host):\(request.port) -> target Google API MITM", targetInference: true))
                    try handleMITM(client: client, host: request.host, initialTLSBytes: plain.extraBytes, sendConnectResponse: true)
                case .blindTunnel:
                    eventSink(.connect("CONNECT \(request.host):\(request.port) -> blind tunnel", targetInference: false))
                    try handleBlindTunnel(client: client, host: request.host, port: request.port, initialBytes: plain.extraBytes, sendConnectResponse: true)
                case .reject:
                    eventSink(.log("CONNECT rejected unsupported target \(request.host):\(request.port)"))
                    try sendAll(ProxyWireProtocol.plainHTTPResponse(status: "403 Forbidden", body: Data("403 Forbidden".utf8)), on: client, timeout: Self.connectHeaderTimeout, phase: "reject-send")
                }
            }
        } catch {
            eventSink(.log("client failed: \(error)"))
            try? sendAll(ProxyWireProtocol.plainHTTPResponse(status: "502 Bad Gateway", body: Data("Bad Gateway".utf8)), on: client, timeout: Self.connectHeaderTimeout, phase: "error-send")
        }
    }

    private static func directTLSHost(from tlsBytes: Data, fallbackListenHost: String) -> String {
        if let serverName = TLSClientHelloParser.serverName(from: tlsBytes),
           !serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return serverName
        }

        let normalized = fallbackListenHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if reverseProxyHosts.contains(normalized) {
            return normalized == "::1" ? "localhost" : normalized
        }
        return "127.0.0.1"
    }

    private static func isReverseProxyHost(_ host: String) -> Bool {
        reverseProxyHosts.contains(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func handleBlindTunnel(client: NWConnection, host: String, port: Int, initialBytes: Data, sendConnectResponse: Bool) throws {
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let metrics = NetworkTunnelMetrics(host: host, port: port, kind: .blindTunnel)
        upstream.start(queue: networkQueue)
        defer { upstream.cancel() }
        try waitReady(upstream, timeout: Self.connectHeaderTimeout, phase: "relay-connect")
        if sendConnectResponse {
            try sendAll(ProxyWireProtocol.connectEstablished, on: client, timeout: Self.connectHeaderTimeout, phase: "connect-established")
        }
        if !initialBytes.isEmpty {
            try sendAll(initialBytes, on: upstream, timeout: Self.connectHeaderTimeout, phase: "blind-replay")
        }
        pumpBidirectional(left: client, right: upstream, metrics: metrics)
        if let summary = metrics.finishSummary() {
            eventSink(.log(summary))
        }
    }

    private func handleMITM(client: NWConnection, host: String, initialTLSBytes: Data, sendConnectResponse: Bool) throws {
        #if canImport(Security)
        if sendConnectResponse {
            try sendAll(ProxyWireProtocol.connectEstablished, on: client, timeout: Self.connectHeaderTimeout, phase: "connect-established")
        }

        let tlsServer = TLSTerminationServer(host: host, certificateAuthority: certificateAuthority, queue: networkQueue)
        try tlsServer.start()
        defer { tlsServer.stop() }

        let relay = NWConnection(host: "localhost", port: NWEndpoint.Port(rawValue: UInt16(tlsServer.port))!, using: .tcp)
        relay.start(queue: networkQueue)
        defer { relay.cancel() }
        try waitReady(relay, timeout: Self.connectHeaderTimeout, phase: "tls-relay-connect")
        if !initialTLSBytes.isEmpty {
            try sendAll(initialTLSBytes, on: relay, timeout: Self.connectHeaderTimeout, phase: "tls-replay")
        }

        let metrics = NetworkTunnelMetrics(host: host, port: 443, kind: .targetInference)
        let rawPump = DispatchGroup()
        rawPump.enter()
        runBlockingNetworkTask {
            self.pump(from: client, to: relay, metrics: metrics, direction: .clientToUpstream)
            rawPump.leave()
        }
        rawPump.enter()
        runBlockingNetworkTask {
            self.pump(from: relay, to: client, metrics: metrics, direction: .upstreamToClient)
            rawPump.leave()
        }

        let tlsConnection = try tlsServer.accept(timeout: Self.tlsReadTimeout)
        defer { tlsConnection.cancel() }
        func finishMITMConnection(grace: TimeInterval = 2) {
            Thread.sleep(forTimeInterval: grace)
            tlsConnection.cancel()
            _ = rawPump.wait(timeout: .now() + 2)
            client.cancel()
            relay.cancel()
            if let summary = metrics.finishSummary() {
                eventSink(.log(summary))
            }
        }
        eventSink(.log("TLS established host=\(host) alpn=http/1.1"))
        let (request, rawRequest) = try readHTTPRequest(connection: tlsConnection)
        let isLocalReverseProxyRequest = Self.isReverseProxyHost(host)
        let routingHost = isLocalReverseProxyRequest
            ? "cloudcode-pa.googleapis.com" : host
        emitRawHTTPLog(rawHTTPRequestDump(label: "INBOUND ANTIGRAVITY REQUEST", host: routingHost, raw: rawRequest))
        eventSink(.log("HTTP \(routingHost) \(request.method) \(request.path) \(requestShapeSummary(request.body))"))

        if HostPolicy.default.decision(for: routingHost, port: 443, path: request.path) == .blindTunnel {
            let response = try forwardToGoogle(host: routingHost, request: request)
            let source = isLocalReverseProxyRequest ? "Google direct local reverse" : "Google direct"
            eventSink(.direct("\(source) \(routingHost)\(request.path) status=\(response.statusCode)"))
            try writeHTTPResponse(response, on: tlsConnection)
        } else if request.path.contains(":fetchAvailableModels") {
            let settings = settingsStore.load()
            let response = try injectProviderModelsIntoAvailableModels(host: routingHost, request: request, settings: settings)
            eventSink(.direct("Google available-models \(routingHost)\(request.path) status=\(response.statusCode)"))
            try writeHTTPResponse(response, on: tlsConnection)
        } else {
            let settings = settingsStore.load()
                let planner = ProxyRequestPlanner(
                    routingEngine: RoutingEngine(
                        config: RoutingEngineConfiguration(
                            customProviderRoutingEnabled: settings.customProviderRoutingEnabled,
                            providerModelAliases: settings.providerModelAliases
                        )
                    )
                )
            let decision = planner.plan(host: routingHost, request: request)
            switch decision {
            case let .forwardToGoogle(forwardedRequest, metadata):
                let response = try forwardToGoogle(host: routingHost, request: forwardedRequest)
                eventSink(.directModel("Google direct model=\(metadata.model) action=\(metadata.action.logName) status=\(response.statusCode)"))
                try writeHTTPResponse(response, on: tlsConnection)
            case let .routeToCheapRouter(payload, metadata, providerID):
                let response = try routeToCheapRouter(payload: payload, metadata: metadata, providerID: providerID, settings: settings)
                eventSink(.routed("provider=\(providerID) model=\(metadata.model) action=\(metadata.action.logName) status=\(response.statusCode)"))
                try writeHTTPResponse(response, on: tlsConnection)
            case let .failClosed(reason):
                eventSink(.log("MITM fail-closed \(routingHost)\(request.path): \(reason)"))
                try writeHTTPResponse(ProxyHTTPResponse(
                    statusCode: 502,
                    headers: ["content-type": "application/json"],
                body: Data(#"{"error":{"message":"AntigravityRouter failed to translate request"}}"#.utf8)
                ), on: tlsConnection)
            }
        }

        finishMITMConnection()
        #else
        throw PorterRuntimeError.securityUnavailable
        #endif
    }

    private func receiveInitialBytes(_ connection: NWConnection) throws -> Data {
        try receiveData(connection, min: 1, max: Self.tlsPeekBytes, timeout: Self.connectHeaderTimeout, phase: "initial-read")
    }

    enum InitialClassification {
        case directTLS(Data)
        case plain((header: Data, extraBytes: Data))
    }

    enum InitialBufferClassification: Equatable {
        case directTLS(Data)
        case plain(Data)
    }

    func classifyInitialBytes(client: NWConnection, initial: Data) throws -> InitialClassification {
        let classified = Self.classifyInitialBufferForTest(initial: initial) {
            try? receiveData(client, min: 1, max: 6 - initial.count, timeout: Self.connectHeaderTimeout, phase: "initial-tls-read")
        }
        switch classified {
        case let .directTLS(data):
            return .directTLS(data)
        case let .plain(data):
            return .plain(try readPlainHeader(client: client, initial: data))
        }
    }

    private func readPlainHeader(client: NWConnection, initial: Data) throws -> (header: Data, extraBytes: Data) {
        var data = initial
        while data.count < Self.maximumInitialHeaderBytes {
            if let split = splitHeader(data) {
                return split
            }
            let next = try receiveData(client, min: 1, max: 4096, timeout: Self.connectHeaderTimeout, phase: "route-parse")
            data.append(next)
        }
        throw PorterRuntimeError.socketFailed("header too large")
    }

    private func splitHeader(_ data: Data) -> (header: Data, extraBytes: Data)? {
        let marker = Data([13, 10, 13, 10])
        guard let range = data.range(of: marker) else { return nil }
        let end = range.upperBound
        return (data.prefix(end), data.suffix(from: end))
    }

    private func pacRequestMethod(from data: Data) -> String? {
        guard let line = String(data: data.prefix(128), encoding: .utf8)?.components(separatedBy: "\r\n").first else {
            return nil
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])
        guard method == "GET" || method == "HEAD",
              path == "/proxy.pac" || path == "/wpad.dat" || path.hasSuffix("/proxy.pac")
        else { return nil }
        return method
    }

    private func isTLSClientHello(_ data: Data) -> Bool {
        data.count >= 6 && data[data.startIndex] == 0x16 && data[data.startIndex + 1] == 0x03 && data[data.startIndex + 5] == 0x01
    }

    private func readHTTPRequest(connection: NWConnection) throws -> (request: HTTPRequestEnvelope, raw: Data) {
        var data = Data()
        while data.count < Self.maximumHTTPRequestBytes {
            let chunk = try receiveData(connection, min: 1, max: 16384, timeout: Self.tlsReadTimeout, phase: "tls-read")
            data.append(chunk)
            if data.count <= 64 {
                eventSink(.log("TLS app-data prefix bytes=\(hexPrefix(data, limit: 32)) ascii=\(asciiPrefix(data, limit: 32))"))
            }
            do {
                let request = try HTTPRequestParser.parse(data)
                let rawLength = rawHTTPRequestLength(parsed: request, received: data)
                return (request, Data(data.prefix(rawLength)))
            } catch HTTPRequestParseError.incomplete {
                continue
            }
        }
        throw PorterRuntimeError.socketFailed("HTTP request too large")
    }

    private func writeHTTPResponse(_ response: ProxyHTTPResponse, on connection: NWConnection) throws {
        let normalized = response.normalizedForClient()
        emitRawHTTPLog(rawProxyHTTPResponseDump(label: "CLIENT RESPONSE TO ANTIGRAVITY", response: normalized))
        var head = "HTTP/1.1 \(normalized.statusCode) \(Self.reasonPhrase(for: normalized.statusCode))\r\n"
        for (name, value) in normalized.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        try sendAll(Data(head.utf8) + normalized.body, on: connection, timeout: Self.tlsReadTimeout, phase: "tls-write")
    }

    private func runBlockingNetworkTask(_ task: @escaping @Sendable () -> Void) {
        Thread.detachNewThread {
            task()
        }
    }

    private func pumpBidirectional(left: NWConnection, right: NWConnection, metrics: NetworkTunnelMetrics) {
        let group = DispatchGroup()
        group.enter()
        runBlockingNetworkTask {
            self.pump(from: left, to: right, metrics: metrics, direction: .clientToUpstream)
            group.leave()
        }
        group.enter()
        runBlockingNetworkTask {
            self.pump(from: right, to: left, metrics: metrics, direction: .upstreamToClient)
            group.leave()
        }
        group.wait()
    }

    private func pump(from source: NWConnection, to target: NWConnection, metrics: NetworkTunnelMetrics, direction: NetworkTunnelDirection) {
        while true {
            do {
                let data = try receiveData(source, min: 1, max: Self.pipeBufferSize, timeout: Self.tlsReadTimeout, phase: "pump-receive")
                if data.isEmpty { return }
                metrics.record(byteCount: data.count, direction: direction)
                try sendAll(data, on: target, timeout: Self.tlsReadTimeout, phase: "pump-send")
            } catch {
                target.cancel()
                source.cancel()
                return
            }
        }
    }

    private func receiveData(_ connection: NWConnection, min: Int, max: Int, timeout: TimeInterval, phase: String) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedBox<Result<Data, Error>>()
        connection.receive(minimumIncompleteLength: min, maximumLength: max) { data, _, complete, error in
            if let error {
                box.value = .failure(PorterRuntimeError.socketFailed("\(phase): \(error)"))
            } else if let data, !data.isEmpty {
                box.value = .success(data)
            } else if complete {
                box.value = .failure(PorterRuntimeError.connectionClosed)
            } else {
                box.value = .failure(PorterRuntimeError.connectionClosed)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw PorterRuntimeError.socketFailed("\(phase): timed out")
        }
        return try box.value?.get() ?? { throw PorterRuntimeError.connectionClosed }()
    }

    private func sendAll(_ data: Data, on connection: NWConnection, timeout: TimeInterval, phase: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedBox<Error>()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                box.value = PorterRuntimeError.socketFailed("\(phase): \(error)")
            }
            semaphore.signal()
        })
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw PorterRuntimeError.socketFailed("\(phase): timed out")
        }
        if let error = box.value {
            throw error
        }
    }

    private func waitReady(_ connection: NWConnection, timeout: TimeInterval, phase: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedBox<Error>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case let .failed(error):
                box.value = PorterRuntimeError.socketFailed("\(phase): \(error)")
                semaphore.signal()
            case .cancelled:
                box.value = PorterRuntimeError.connectionClosed
                semaphore.signal()
            default:
                break
            }
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw PorterRuntimeError.socketFailed("\(phase): timed out")
        }
        if let error = box.value {
            throw error
        }
    }

    private func routeToCheapRouter(payload: CheapRouterRequestPayload, metadata: ModelRequestMetadata, providerID: String, settings: PorterSettings) throws -> ProxyHTTPResponse {
        guard let provider = providerConfig(providerID: providerID, settings: settings) else {
            return ProxyHTTPResponse(
                statusCode: 502,
                headers: ["content-type": "application/json"],
                body: Data(#"{"error":{"message":"target provider config is missing"}}"#.utf8)
            )
        }
        guard let apiKey = try providerAPIKey(providerID: provider.id), !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ProxyHTTPResponse(
                statusCode: 401,
                headers: ["content-type": "application/json"],
                body: Data(#"{"error":{"message":"target provider API key is missing"}}"#.utf8)
            )
        }
        let urlRequest = targetProviderURLRequest(provider: provider, apiKey: apiKey, payload: payload)
        emitRawHTTPLog(rawURLRequestDump(label: "UPSTREAM TARGET PROVIDER REQUEST \(provider.id)", request: urlRequest))
        let raw = try perform(urlRequest, session: cheapRouterSession)
        emitRawHTTPLog(rawHTTPURLResponseDump(label: "UPSTREAM TARGET PROVIDER RESPONSE \(provider.id)", statusCode: raw.statusCode, headers: raw.headers, body: raw.body))
        let cheapRouterResponse = CheapRouterResponse(statusCode: raw.statusCode, headers: raw.headers, body: raw.body)
        return ResponseTranslator().translate(response: cheapRouterResponse, metadata: metadata)
    }

    private func providerConfig(providerID: String, settings: PorterSettings) -> TargetProviderConfig? {
        guard let normalized = TargetProviderConfig.normalizedProviderID(providerID) else { return nil }
        return settings.targetProviders.first { $0.id == normalized && $0.enabled }
    }

    private func providerAPIKey(providerID: String) throws -> String? {
        guard let normalized = TargetProviderConfig.normalizedProviderID(providerID) else { return nil }
        if normalized == TargetProviderConfig.defaultProviderID {
            return try keychainStore.string(for: .cheapRouterAPIKey)
        }
        return try providerKeychainStoreFactory(normalized).string(for: .cheapRouterAPIKey)
    }

    private static func providerKeychainService(providerID: String, legacy: Bool) -> String {
        let prefix = legacy ? "uk.cheaprouter.AntigravityPorter.provider" : "uk.cheaprouter.AntigravityRouter.provider"
        return "\(prefix).\(providerID)"
    }

    private func targetProviderURLRequest(provider: TargetProviderConfig, apiKey: String, payload: CheapRouterRequestPayload) -> URLRequest {
        CheapRouterClient(configuration: .init(baseURL: provider.baseURL, apiKey: apiKey))
            .urlRequest(endpoint: payload.endpoint, body: payload.body)
    }

    func targetProviderURLRequestForTest(payload: CheapRouterRequestPayload, providerID: String, settings: PorterSettings) throws -> URLRequest {
        guard let provider = providerConfig(providerID: providerID, settings: settings),
              let apiKey = try providerAPIKey(providerID: provider.id),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw PorterRuntimeError.invalidHTTPResponse
        }
        return targetProviderURLRequest(provider: provider, apiKey: apiKey, payload: payload)
    }

    private func injectProviderModelsIntoAvailableModels(host: String, request: HTTPRequestEnvelope, settings: PorterSettings) throws -> ProxyHTTPResponse {
        let googleResponse = try forwardToGoogle(host: host, request: request.removingProxyHeaders())
        guard settings.customProviderRoutingEnabled else {
            updateProviderModelAliases([:])
            eventSink(.log("available-models provider injection skipped: provider models disabled"))
            return googleResponse
        }
        guard (200..<300).contains(googleResponse.statusCode) else {
            eventSink(.log("available-models provider injection skipped: google status=\(googleResponse.statusCode)"))
            return googleResponse
        }
        var prefixedModels: [ProviderModel] = []
        var skippedProviders: [String] = []
        for provider in settings.targetProviders where provider.enabled {
            let apiKey: String
            do {
                apiKey = try providerAPIKey(providerID: provider.id) ?? ""
            } catch {
                eventSink(.log("available-models provider \(provider.id) skipped: api key read failed \(error)"))
                skippedProviders.append(provider.id)
                continue
            }
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                eventSink(.log("available-models provider \(provider.id) skipped: api key missing"))
                skippedProviders.append(provider.id)
                continue
            }

            let client = CheapRouterClient(configuration: .init(baseURL: provider.baseURL, apiKey: apiKey))
            let urlRequest = client.urlRequest(endpoint: .models, body: Data())
            emitRawHTTPLog(rawURLRequestDump(label: "UPSTREAM PROVIDER MODELS REQUEST \(provider.id)", request: urlRequest))
            do {
                let raw = try perform(urlRequest, session: cheapRouterSession)
                emitRawHTTPLog(rawHTTPURLResponseDump(label: "UPSTREAM PROVIDER MODELS RESPONSE \(provider.id)", statusCode: raw.statusCode, headers: raw.headers, body: raw.body))
                guard (200..<300).contains(raw.statusCode) else {
                    eventSink(.log("available-models provider \(provider.id) skipped: status=\(raw.statusCode)"))
                    skippedProviders.append(provider.id)
                    continue
                }
                prefixedModels += try CheapRouterClient.parseModelsResponse(raw.body).map {
                    ProviderModel(id: "\(provider.id)/\($0.id)")
                }.filter {
                    !settings.disabledProviderModelIDs.contains($0.id)
                }
            } catch {
                eventSink(.log("available-models provider \(provider.id) skipped: \(error)"))
                skippedProviders.append(provider.id)
            }
        }
        guard !prefixedModels.isEmpty else {
            updateProviderModelAliases([:])
            eventSink(.log("available-models provider injection skipped: no provider models loaded"))
            return googleResponse
        }

        let report = AntigravityModelCatalogInjector.injectProviderModelsWithReport(prefixedModels, into: googleResponse.body)
        updateProviderModelAliases(report.modelAliases)
        eventSink(.log("available-models provider models fetched=\(report.providerModelCount) inserted=\(report.insertedModelCount) skipped=\(skippedProviders.joined(separator: ",")) response_bytes=\(report.body.count)"))
        let response = ProxyHTTPResponse(statusCode: googleResponse.statusCode, headers: googleResponse.headers, body: report.body)
        emitRawHTTPLog(rawProxyHTTPResponseDump(label: "INJECTED AVAILABLE MODELS RESPONSE", response: response))
        return response
    }

    private func updateProviderModelAliases(_ aliases: [String: ProviderModelAlias]) {
        var settings = settingsStore.load()
        settings.providerModelAliases = aliases
        do {
            try settingsStore.save(settings)
        } catch {
            eventSink(.log("available-models provider aliases persist failed: \(error)"))
        }
    }

    private func forwardToGoogle(host: String, request: HTTPRequestEnvelope) throws -> ProxyHTTPResponse {
        let upstreamHost = GoogleUpstreamHostPolicy.host(for: host)
        guard let url = URL(string: "https://\(upstreamHost)\(request.path)") else {
            throw PorterRuntimeError.invalidURL("https://\(upstreamHost)\(request.path)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue(upstreamHost, forHTTPHeaderField: "Host")
        for (name, value) in request.headers {
            let lower = name.lowercased()
            guard lower != "host",
                  lower != "content-length",
                  lower != "connection",
                  lower != "transfer-encoding",
                  lower != "accept-encoding",
                  !lower.hasPrefix("proxy-")
            else { continue }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        emitRawHTTPLog(rawURLRequestDump(label: "UPSTREAM GOOGLE REQUEST", request: urlRequest))
        let raw = try perform(urlRequest, session: googleSession)
        emitRawHTTPLog(rawHTTPURLResponseDump(label: "UPSTREAM GOOGLE RESPONSE", statusCode: raw.statusCode, headers: raw.headers, body: raw.body))
        return ProxyHTTPResponse(statusCode: raw.statusCode, headers: raw.headers, body: raw.body)
    }

    private func perform(_ request: URLRequest, session: URLSession, timeout: TimeInterval? = nil) throws -> (statusCode: Int, headers: [String: String], body: Data) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedBox<Result<(Int, [String: String], Data), Error>>()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                box.value = .failure(error)
            } else if let response = response as? HTTPURLResponse {
                let headers = Dictionary(uniqueKeysWithValues: response.allHeaderFields.compactMap { key, value -> (String, String)? in
                    guard let key = key as? String else { return nil }
                    return (key, String(describing: value))
                })
                box.value = .success((response.statusCode, headers, data ?? Data()))
            } else {
                box.value = .failure(PorterRuntimeError.invalidHTTPResponse)
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + (timeout ?? Self.upstreamTimeout)) == .timedOut {
            task.cancel()
            throw PorterRuntimeError.upstreamTimedOut
        }
        return try box.value?.get() ?? { throw PorterRuntimeError.invalidHTTPResponse }()
    }

    private func requestShapeSummary(_ body: Data) -> String {
        guard !body.isEmpty else { return "body_bytes=0" }
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            return "body_bytes=\(body.count) json=unparseable"
        }
        let model = firstStringValue(named: "model", in: object) ?? "<none>"
        let keys = topLevelKeys(in: object).prefix(12).joined(separator: ",")
        return "body_bytes=\(body.count) model=\(model) keys=[\(keys)]"
    }

    private func topLevelKeys(in value: Any) -> [String] {
        guard let object = value as? [String: Any] else { return [] }
        return object.keys.sorted()
    }

    private func firstStringValue(named targetKey: String, in value: Any) -> String? {
        if let object = value as? [String: Any] {
            if let value = object[targetKey] as? String {
                return value
            }
            for child in object.values {
                if let found = firstStringValue(named: targetKey, in: child) {
                    return found
                }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let found = firstStringValue(named: targetKey, in: child) {
                    return found
                }
            }
        }
        return nil
    }

    private func emitRawHTTPLog(_ line: @autoclosure () -> String) {
        let settings = settingsStore.load()
        guard settings.loggingEnabled,
              settings.rawHTTPLoggingEnabled || settings.unsafeFullRawHTTPLoggingEnabled
        else { return }
        eventSink(.log(line()))
    }

    private func rawHTTPRequestLength(parsed request: HTTPRequestEnvelope, received: Data) -> Int {
        let headerEnd: Data.Index
        if let range = received.range(of: Data("\r\n\r\n".utf8)) {
            headerEnd = range.upperBound
        } else if let range = received.range(of: Data("\n\n".utf8)) {
            headerEnd = range.upperBound
        } else {
            return received.count
        }

        if let contentLength = request.headers["content-length"],
           let bodyLength = Int(contentLength),
           bodyLength >= 0 {
            return min(received.count, headerEnd + bodyLength)
        }
        if request.headers["transfer-encoding"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "chunked" }) == true {
            let rawBody = Data(received[headerEnd...])
            if let decoded = try? HTTPRequestParser.decodeChunkedBody(rawBody) {
                return min(received.count, headerEnd + decoded.consumedBytes)
            }
        }
        return received.count
    }

    private func rawHTTPRequestDump(label: String, host: String, raw: Data) -> String {
        let settings = settingsStore.load()
        let rendered = HTTPRawLogPolicy.renderHTTPRequest(raw, unsafeFullRaw: settings.unsafeFullRawHTTPLoggingEnabled)
        return """
        ===== \(label) host=\(host) bytes=\(raw.count) =====
        \(rendered)
        ===== END \(label) =====
        """
    }

    private func rawURLRequestDump(label: String, request: URLRequest) -> String {
        let settings = settingsStore.load()
        let unsafeFullRaw = settings.unsafeFullRawHTTPLoggingEnabled
        let url = request.url
        let method = request.httpMethod ?? "GET"
        let path = unsafeFullRaw ? Self.pathAndQuery(for: url) : HTTPRawLogPolicy.redactedPathAndQuery(for: url)
        var headers = HTTPRawLogPolicy.redactedHeaders(request.allHTTPHeaderFields ?? [:], unsafeFullRaw: unsafeFullRaw)
        if headers.keys.contains(where: { $0.lowercased() == "host" }) == false, let host = url?.host {
            headers["Host"] = host
        }
        if let body = request.httpBody,
           headers.keys.contains(where: { $0.lowercased() == "content-length" }) == false {
            headers["Content-Length"] = "\(body.count)"
        }
        var lines = ["\(method) \(path) HTTP/1.1"]
        lines.append(contentsOf: sortedHeaderLines(headers))
        lines.append("")
        lines.append(HTTPRawLogPolicy.renderBody(request.httpBody ?? Data(), unsafeFullRaw: unsafeFullRaw))
        return """
        ===== \(label) url=\(HTTPRawLogPolicy.redactedURLString(url, unsafeFullRaw: unsafeFullRaw)) bytes=\((request.httpBody ?? Data()).count) =====
        \(lines.joined(separator: "\r\n"))
        ===== END \(label) =====
        """
    }

    private func rawHTTPURLResponseDump(label: String, statusCode: Int, headers: [String: String], body: Data) -> String {
        let unsafeFullRaw = settingsStore.load().unsafeFullRawHTTPLoggingEnabled
        var lines = ["HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))"]
        lines.append(contentsOf: sortedHeaderLines(HTTPRawLogPolicy.redactedHeaders(headers, unsafeFullRaw: unsafeFullRaw)))
        lines.append("")
        lines.append(HTTPRawLogPolicy.renderBody(body, unsafeFullRaw: unsafeFullRaw))
        return """
        ===== \(label) bytes=\(body.count) =====
        \(lines.joined(separator: "\r\n"))
        ===== END \(label) =====
        """
    }

    private func rawProxyHTTPResponseDump(label: String, response: ProxyHTTPResponse) -> String {
        rawHTTPURLResponseDump(label: label, statusCode: response.statusCode, headers: response.headers, body: response.body)
    }

    private func sortedHeaderLines(_ headers: [String: String]) -> [String] {
        headers
            .sorted { left, right in left.key.localizedCaseInsensitiveCompare(right.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
    }

    private static func pathAndQuery(for url: URL?) -> String {
        guard let url else { return "/" }
        var output = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            output += "?\(query)"
        }
        return output
    }

    private func hexPrefix(_ data: Data, limit: Int) -> String {
        data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func asciiPrefix(_ data: Data, limit: Int) -> String {
        String(decoding: data.prefix(limit).map { byte in
            (32...126).contains(byte) ? byte : UInt8(ascii: ".")
        }, as: UTF8.self)
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "OK"
        }
    }
}

enum HTTPRawLogPolicy {
    static let maximumBodyBytes = 256 * 1024

    private static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-goog-api-key",
        "x-api-key",
        "api-key"
    ]

    private static let sensitiveQueryNames: Set<String> = [
        "key",
        "api_key",
        "apikey",
        "token",
        "access_token",
        "id_token",
        "refresh_token",
        "authorization"
    ]

    static func renderHTTPRequest(_ raw: Data, unsafeFullRaw: Bool) -> String {
        guard let split = splitHeadersAndBody(raw),
              let headerText = String(data: split.header, encoding: .utf8)
        else {
            return "<redacted raw request bytes=\(raw.count)>"
        }

        let normalized = headerText.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, !unsafeFullRaw {
            lines[0] = redactedRequestLine(first)
        }
        for index in lines.indices.dropFirst() {
            lines[index] = redactedHeaderLine(lines[index])
        }
        lines.append("")
        lines.append(renderBody(split.body, unsafeFullRaw: unsafeFullRaw))
        return lines.joined(separator: "\r\n")
    }

    static func redactedHeaders(_ headers: [String: String], unsafeFullRaw: Bool) -> [String: String] {
        return Dictionary(uniqueKeysWithValues: headers.map { name, value in
            sensitiveHeaderNames.contains(name.lowercased()) ? (name, "[REDACTED]") : (name, value)
        })
    }

    static func redactedURLString(_ url: URL?, unsafeFullRaw: Bool) -> String {
        guard let url else { return "<nil>" }
        guard !unsafeFullRaw else { return url.absoluteString }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems
        components?.queryItems = redactedQueryItems(queryItems)
        return components?.url?.absoluteString ?? url.absoluteString
    }

    static func redactedPathAndQuery(for url: URL?) -> String {
        guard let url else { return "/" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = nil
        components?.host = nil
        components?.port = nil
        components?.user = nil
        components?.password = nil
        let queryItems = components?.queryItems
        components?.queryItems = redactedQueryItems(queryItems)
        var output = url.path.isEmpty ? "/" : url.path
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            output += "?\(query)"
        }
        return output
    }

    static func renderBody(_ body: Data, unsafeFullRaw: Bool) -> String {
        guard !body.isEmpty else { return "" }
        guard unsafeFullRaw else { return "<redacted body bytes=\(body.count)>" }

        let prefix = body.prefix(maximumBodyBytes)
        let suffix = body.count > maximumBodyBytes ? "\n<truncated body bytes=\(body.count - maximumBodyBytes)>" : ""
        if let text = String(data: prefix, encoding: .utf8) {
            return text + suffix
        }
        return "<base64 body bytes=\(body.count)>\n\(Data(prefix).base64EncodedString())\(suffix)"
    }

    private static func splitHeadersAndBody(_ raw: Data) -> (header: Data, body: Data)? {
        if let range = raw.range(of: Data("\r\n\r\n".utf8)) {
            return (Data(raw[..<range.lowerBound]), Data(raw[range.upperBound...]))
        }
        if let range = raw.range(of: Data("\n\n".utf8)) {
            return (Data(raw[..<range.lowerBound]), Data(raw[range.upperBound...]))
        }
        return nil
    }

    private static func redactedRequestLine(_ line: String) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return line }
        let path = String(parts[1])
        let redactedPath = redactedPath(path)
        return "\(parts[0]) \(redactedPath) \(parts[2])"
    }

    private static func redactedPath(_ path: String) -> String {
        guard let components = URLComponents(string: path) else { return path }
        var mutable = components
        mutable.queryItems = redactedQueryItems(components.queryItems)
        var output = mutable.path.isEmpty ? path.components(separatedBy: "?").first ?? "/" : mutable.path
        if let query = mutable.percentEncodedQuery, !query.isEmpty {
            output += "?\(query)"
        }
        return output
    }

    private static func redactedHeaderLine(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        let name = String(line[..<colon])
        if sensitiveHeaderNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return "\(name): [REDACTED]"
        }
        return line
    }

    private static func redactedQueryItems(_ items: [URLQueryItem]?) -> [URLQueryItem]? {
        items?.map { item in
            sensitiveQueryNames.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: "[REDACTED]")
                : item
        }
    }
}

#if canImport(Security)
private final class TLSTerminationServer: @unchecked Sendable {
    private let host: String
    private let certificateAuthority: CertificateAuthority
    private let queue: DispatchQueue
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let acceptSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var listener: NWListener?
    private var accepted: NWConnection?
    private var failure: Error?

    private(set) var port: Int = 0

    init(host: String, certificateAuthority: CertificateAuthority, queue: DispatchQueue) {
        self.host = host
        self.certificateAuthority = certificateAuthority
        self.queue = queue
    }

    func start() throws {
        let params = try makeParameters()
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 0)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.lock.lock()
                    self.accepted = connection
                    self.lock.unlock()
                    self.acceptSemaphore.signal()
                case let .failed(error):
                    self.lock.lock()
                    self.failure = PorterRuntimeError.tlsFailed("tls-handshake: \(error)")
                    self.lock.unlock()
                    self.acceptSemaphore.signal()
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.readySemaphore.signal()
            case let .failed(error):
                self?.lock.lock()
                self?.failure = PorterRuntimeError.tlsFailed("tls-listen: \(error)")
                self?.lock.unlock()
                self?.readySemaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        if readySemaphore.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw PorterRuntimeError.tlsFailed("tls-listen: timed out")
        }
        if let failure {
            listener.cancel()
            throw failure
        }
        guard let rawPort = listener.port?.rawValue else {
            listener.cancel()
            throw PorterRuntimeError.tlsFailed("tls-listen: missing port")
        }
        port = Int(rawPort)
    }

    func accept(timeout: TimeInterval) throws -> NWConnection {
        if acceptSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw PorterRuntimeError.tlsFailed("tls-handshake: timed out")
        }
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw failure
        }
        guard let accepted else {
            throw PorterRuntimeError.tlsFailed("tls-handshake: no connection")
        }
        return accepted
    }

    func stop() {
        listener?.cancel()
        accepted?.cancel()
    }

    private func makeParameters() throws -> NWParameters {
        let identity = try certificateAuthority.leafSecIdentity(for: host, policy: .allowIntercept)
        guard let secIdentity = sec_identity_create(identity) else {
            throw PorterRuntimeError.tlsFailed("create-sec-identity")
        }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(options, secIdentity)
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        return NWParameters(tls: tls, tcp: tcp)
    }
}
#endif

private enum NetworkTunnelKind: String {
    case targetInference = "target"
    case blindTunnel = "blind"
}

private enum NetworkTunnelDirection {
    case clientToUpstream
    case upstreamToClient
}

private final class NetworkTunnelMetrics: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let kind: NetworkTunnelKind
    private let startedAt = Date()
    private let lock = NSLock()
    private var clientToUpstreamBytes = 0
    private var upstreamToClientBytes = 0
    private var closed = false

    init(host: String, port: Int, kind: NetworkTunnelKind) {
        self.host = host
        self.port = port
        self.kind = kind
    }

    func record(byteCount: Int, direction: NetworkTunnelDirection) {
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

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
