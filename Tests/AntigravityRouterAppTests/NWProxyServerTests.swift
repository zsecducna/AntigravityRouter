import AntigravityRouterCore
import Darwin
import Foundation
import Network
import Security
import XCTest
@testable import AntigravityRouterApp

final class NWProxyServerTests: XCTestCase {
    func testRawHTTPPolicyRedactsHeadersQueriesAndBodiesByDefault() {
        let raw = Data("""
        POST /v1internal:generateContent?key=google-key HTTP/1.1\r
        Host: cloudcode-pa.googleapis.com\r
        Authorization: Bearer google-token\r
        X-Goog-Api-Key: google-key\r
        Content-Length: 25\r
        \r
        {"prompt":"keep secret"}
        """.utf8)

        let rendered = HTTPRawLogPolicy.renderHTTPRequest(raw, unsafeFullRaw: false)

        XCTAssertTrue(rendered.contains("key=%5BREDACTED%5D"))
        XCTAssertTrue(rendered.contains("Authorization: [REDACTED]"))
        XCTAssertTrue(rendered.contains("X-Goog-Api-Key: [REDACTED]"))
        XCTAssertTrue(rendered.contains("<redacted body bytes="))
        XCTAssertFalse(rendered.contains("google-token"))
        XCTAssertFalse(rendered.contains("keep secret"))
    }

    func testRawHTTPPolicyUnsafeModeKeepsBodyButCapsSize() {
        let body = Data(repeating: UInt8(ascii: "a"), count: HTTPRawLogPolicy.maximumBodyBytes + 4)

        let rendered = HTTPRawLogPolicy.renderBody(body, unsafeFullRaw: true)

        XCTAssertTrue(rendered.contains("<truncated body bytes=4>"))
    }

    func testRawHTTPPolicyUnsafeModeKeepsRequestTargetAndBodyWithCredentialHeadersRedacted() {
        let raw = Data("""
        POST /v1internal:generateContent?key=google-key HTTP/1.1\r
        Host: cloudcode-pa.googleapis.com\r
        Authorization: Bearer google-token\r
        X-Trace-Id: trace-123\r
        \r
        {"prompt":"visible body"}
        """.utf8)

        let rendered = HTTPRawLogPolicy.renderHTTPRequest(raw, unsafeFullRaw: true)

        XCTAssertTrue(rendered.contains("POST /v1internal:generateContent?key=google-key HTTP/1.1"))
        XCTAssertTrue(rendered.contains("Authorization: [REDACTED]"))
        XCTAssertTrue(rendered.contains("X-Trace-Id: trace-123"))
        XCTAssertTrue(rendered.contains("visible body"))
        XCTAssertFalse(rendered.contains("google-token"))
    }

    func testFileKeychainStoreUsesPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRouterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileKeychainStore(directory: directory)

        try store.setData(Data("secret".utf8), for: .certificateAuthorityPrivateKey)

        let file = directory.appendingPathComponent("\(KeychainSecretKey.certificateAuthorityPrivateKey.rawValue).bin")
        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber).intValue & 0o777
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }

    func testClassifiesSplitDirectTLSClientHello() throws {
        let hello = makeClientHello(serverName: "cloudcode-pa.googleapis.com")
        var chunks = [Data(hello.dropFirst(2))]
        let classification = NWProxyServer.classifyInitialBufferForTest(initial: Data(hello.prefix(2))) {
            chunks.isEmpty ? nil : chunks.removeFirst()
        }
        if case let .directTLS(bytes) = classification {
            XCTAssertEqual(bytes, hello)
            XCTAssertEqual(TLSClientHelloParser.serverName(from: bytes), "cloudcode-pa.googleapis.com")
        } else {
            XCTFail("expected directTLS, got \(classification)")
        }
    }

    func testCONNECTMITMNegotiatesHTTP11ALPN() throws {
        let events = RuntimeEventRecorder()
        let server = try makeServer(events: events)
        try server.start()
        defer { server.stop() }
        let proxyPort = server.boundPort
        XCTAssertGreaterThan(proxyPort, 0)

        let delegate = MetricsDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: proxyPort,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: proxyPort
        ]
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let finished = expectation(description: "request finishes")
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:generateContent")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"gemini-test","contents":[]}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(request.httpBody?.count ?? 0)", forHTTPHeaderField: "Content-Length")
        session.dataTask(with: request) { _, _, _ in
            finished.fulfill()
        }.resume()
        wait(for: [finished], timeout: 8)

        XCTAssertTrue(delegate.protocols.contains("http/1.1"), "protocols=\(delegate.protocols)")
        let capturedEvents = events.snapshot
        XCTAssertTrue(capturedEvents.contains { event in
            if case let .connect(line, targetInference) = event {
                return targetInference && line.contains("CONNECT cloudcode-pa.googleapis.com:443")
            }
            return false
        }, "\(capturedEvents)")
    }

    func testDirectTLSNegotiatesHTTP11ALPN() throws {
        let events = RuntimeEventRecorder()
        let server = try makeServer(events: events)
        try server.start()
        defer { server.stop() }

        let negotiated = try directTLSNegotiatedProtocol(port: server.boundPort, serverName: "cloudcode-pa.googleapis.com")
        XCTAssertEqual(negotiated, "http/1.1")
        XCTAssertTrue(events.snapshot.contains { event in
            if case let .connect(line, targetInference) = event {
                return targetInference && line.contains("DIRECT TLS cloudcode-pa.googleapis.com:443")
            }
            return false
        }, "\(events.snapshot)")
    }

    func testDirectTLSWithoutSNIUsesLocalReverseProxyHost() throws {
        let events = RuntimeEventRecorder()
        let server = try makeServer(events: events)
        try server.start()
        defer { server.stop() }

        let negotiated = try directTLSNegotiatedProtocol(port: server.boundPort, serverName: nil)
        XCTAssertEqual(negotiated, "http/1.1")
        XCTAssertTrue(events.snapshot.contains { event in
            if case let .connect(line, targetInference) = event {
                return targetInference && line.contains("DIRECT TLS 127.0.0.1:443")
            }
            return false
        }, "\(events.snapshot)")
    }

    func testFixedLoopbackPortStarts() throws {
        let events = RuntimeEventRecorder()
        let port = try reserveLoopbackPort()
        let server = try makeServer(events: events, port: port)
        try server.start()
        defer { server.stop() }

        XCTAssertEqual(server.boundPort, port)
        XCTAssertTrue(canConnect(host: "127.0.0.1", port: port))
        XCTAssertTrue(canConnect(host: "::1", port: port))
    }

    func testTargetProviderRequestsUseProviderSpecificKeyAndUnprefixedModel() throws {
        let events = RuntimeEventRecorder()
        let defaultKeychain = InMemoryKeychainStore()
        try defaultKeychain.setString("default-key", for: .cheapRouterAPIKey)
        let providerKeys = [
            "openai": "openai-key",
            "anthropic": "anthropic-key"
        ]
        let settingsStore = UserDefaultsSettingsStore(
            userDefaults: InMemorySettingsDataStore(),
            key: "NWProxyServerTests-\(UUID().uuidString)"
        )
        let server = NWProxyServer(
            host: "127.0.0.1",
            port: 0,
            settingsStore: settingsStore,
            keychainStore: defaultKeychain,
            providerKeychainStoreFactory: { providerID in
                let keychain = InMemoryKeychainStore()
                if let apiKey = providerKeys[providerID] {
                    try? keychain.setString(apiKey, for: .cheapRouterAPIKey)
                }
                return keychain
            },
            certificateAuthority: CertificateAuthority(keychain: defaultKeychain),
            eventSink: { events.append($0) },
            pacScriptProvider: { "function FindProxyForURL(url, host) { return 'DIRECT'; }" }
        )
        let settings = PorterSettings(
            cheapRouterBaseURL: URL(string: "https://default.example")!,
            localProxyHost: "127.0.0.1",
            localProxyPort: 8877,
            launchAtLoginEnabled: false,
            customProviderRoutingEnabled: true,
            targetProviders: [
                TargetProviderConfig(id: "openai", baseURL: URL(string: "https://openai.example")!),
                TargetProviderConfig(id: "anthropic", baseURL: URL(string: "https://anthropic.example")!)
            ]
        )
        let openAIPayload = CheapRouterRequestPayload(
            endpoint: .responses,
            model: "gpt-5.5",
            body: Data(#"{"model":"gpt-5.5","input":[]}"#.utf8)
        )
        let anthropicPayload = CheapRouterRequestPayload(
            endpoint: .responses,
            model: "claude-sonnet-4-6",
            body: Data(#"{"model":"claude-sonnet-4-6","input":[]}"#.utf8)
        )

        let openAIRequest = try server.targetProviderURLRequestForTest(payload: openAIPayload, providerID: "openai", settings: settings)
        let anthropicRequest = try server.targetProviderURLRequestForTest(payload: anthropicPayload, providerID: "anthropic", settings: settings)

        XCTAssertEqual(openAIRequest.url?.absoluteString, "https://openai.example/v1/responses")
        XCTAssertEqual(openAIRequest.value(forHTTPHeaderField: "Authorization"), "Bearer openai-key")
        XCTAssertEqual(String(decoding: openAIRequest.httpBody ?? Data(), as: UTF8.self), #"{"model":"gpt-5.5","input":[]}"#)
        XCTAssertFalse(String(decoding: openAIRequest.httpBody ?? Data(), as: UTF8.self).contains("openai/gpt-5.5"))
        XCTAssertEqual(anthropicRequest.url?.absoluteString, "https://anthropic.example/v1/responses")
        XCTAssertEqual(anthropicRequest.value(forHTTPHeaderField: "Authorization"), "Bearer anthropic-key")
        XCTAssertEqual(String(decoding: anthropicRequest.httpBody ?? Data(), as: UTF8.self), #"{"model":"claude-sonnet-4-6","input":[]}"#)
        XCTAssertFalse(String(decoding: anthropicRequest.httpBody ?? Data(), as: UTF8.self).contains("anthropic/claude-sonnet-4-6"))
    }

    private func makeServer(events: RuntimeEventRecorder, port: Int = 0) throws -> NWProxyServer {
        let keychain = InMemoryKeychainStore()
        let settingsStore = UserDefaultsSettingsStore(
            userDefaults: InMemorySettingsDataStore(),
            key: "NWProxyServerTests-\(UUID().uuidString)"
        )
        try settingsStore.save(PorterSettings.defaults)
        return NWProxyServer(
            host: "127.0.0.1",
            port: port,
            settingsStore: settingsStore,
            keychainStore: keychain,
            certificateAuthority: CertificateAuthority(keychain: keychain),
            eventSink: { events.append($0) },
            pacScriptProvider: { "function FindProxyForURL(url, host) { return 'DIRECT'; }" }
        )
    }

    private func reserveLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        XCTAssertEqual(nameResult, 0)
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func canConnect(host: String, port: Int) -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let ready = expectation(description: "connect \(host)")
        let connected = TestBox<Bool>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connected.value = true
                ready.fulfill()
            case .failed:
                connected.value = false
                ready.fulfill()
            default:
                break
            }
        }
        connection.start(queue: .global())
        wait(for: [ready], timeout: 5)
        connection.cancel()
        return connected.value == true
    }

    private func makeClientHello(serverName: String) -> Data {
        let hostBytes = Array(serverName.utf8)
        var extensions = Data()
        extensions.append(contentsOf: [0x00, 0x00])
        let serverNameListLength = UInt16(hostBytes.count + 3)
        let extensionLength = UInt16(Int(serverNameListLength) + 2)
        extensions.append(UInt8(extensionLength >> 8))
        extensions.append(UInt8(extensionLength & 0xff))
        extensions.append(UInt8(serverNameListLength >> 8))
        extensions.append(UInt8(serverNameListLength & 0xff))
        extensions.append(0x00)
        extensions.append(UInt8(hostBytes.count >> 8))
        extensions.append(UInt8(hostBytes.count & 0xff))
        extensions.append(contentsOf: hostBytes)

        var body = Data()
        body.append(contentsOf: [0x03, 0x03])
        body.append(Data(repeating: 0x01, count: 32))
        body.append(0x00)
        body.append(contentsOf: [0x00, 0x02, 0x13, 0x01])
        body.append(0x01)
        body.append(0x00)
        body.append(UInt8(extensions.count >> 8))
        body.append(UInt8(extensions.count & 0xff))
        body.append(extensions)

        var handshake = Data([0x01])
        let length = body.count
        handshake.append(UInt8((length >> 16) & 0xff))
        handshake.append(UInt8((length >> 8) & 0xff))
        handshake.append(UInt8(length & 0xff))
        handshake.append(body)

        var record = Data([0x16, 0x03, 0x01])
        record.append(UInt8(handshake.count >> 8))
        record.append(UInt8(handshake.count & 0xff))
        record.append(handshake)
        return record
    }

    private func directTLSNegotiatedProtocol(port: Int, serverName: String?) throws -> String {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let serverName {
            sec_protocol_options_set_tls_server_name(options, serverName)
        }
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
        sec_protocol_options_set_verify_block(options, { _, _, complete in
            complete(true)
        }, DispatchQueue.global())
        let parameters = NWParameters(tls: tls)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: parameters)
        let ready = expectation(description: "tls ready")
        let readyError = TestBox<Error>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.fulfill()
            case let .failed(error):
                readyError.value = error
                ready.fulfill()
            default:
                break
            }
        }
        connection.start(queue: .global())
        wait(for: [ready], timeout: 5)
        if let capturedReadyError = readyError.value {
            throw capturedReadyError
        }
        if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
           let protocolPointer = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata) {
            connection.cancel()
            return String(cString: protocolPointer)
        }

        let received = expectation(description: "tls metadata")
        let negotiated = TestBox<String>()
        let receiveError = TestBox<Error>()
        connection.send(content: Data("GET /v1internal:generateContent HTTP/1.1\r\nHost: cloudcode-pa.googleapis.com\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, context, _, error in
            if let error {
                receiveError.value = error
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
               let protocolPointer = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata) {
                negotiated.value = String(cString: protocolPointer)
            }
            received.fulfill()
        }
        wait(for: [received], timeout: 5)
        connection.cancel()
        if let capturedReceiveError = receiveError.value, negotiated.value == nil {
            throw capturedReceiveError
        }
        return try XCTUnwrap(negotiated.value)
    }
}

private final class TestBox<Value>: @unchecked Sendable {
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

private final class RuntimeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProxyRuntimeEvent] = []

    var snapshot: [ProxyRuntimeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func append(_ event: ProxyRuntimeEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

private final class MetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedProtocols: [String] = []

    var protocols: [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedProtocols
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        capturedProtocols.append(contentsOf: metrics.transactionMetrics.compactMap(\.networkProtocolName))
        lock.unlock()
    }
}

private final class InMemorySettingsDataStore: SettingsDataStoring {
    private var storage: [String: Data] = [:]

    func settingsData(forKey key: String) -> Data? {
        storage[key]
    }

    func setSettingsData(_ value: Data, forKey key: String) {
        storage[key] = value
    }

    func removeObject(forKey key: String) {
        storage.removeValue(forKey: key)
    }
}
