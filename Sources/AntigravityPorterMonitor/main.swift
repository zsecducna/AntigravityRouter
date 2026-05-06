import Darwin
import Foundation
import Network

private func argumentValue(_ name: String, default defaultValue: String) -> String {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return defaultValue
    }
    return args[index + 1]
}

private func printUsage() {
    print("usage: AntigravityPorterMonitor [--check --port <port> --json-log]")
}

private func runCheckMode() throws -> Never {
    let requestedPort = UInt16(argumentValue("--port", default: "0")) ?? 0
    let jsonLog = CommandLine.arguments.contains("--json-log")
    let queue = DispatchQueue(label: "uk.cheaprouter.AntigravityPorter.monitor.check")
    let listeners = try startCheckListeners(port: requestedPort, queue: queue)
    let ipv4 = listeners.first { $0.host == "127.0.0.1" }
    let ipv6 = listeners.first { $0.host == "::1" }
    if jsonLog {
        let payload = [
            "\"event\":\"ready\"",
            "\"mode\":\"network-framework-check\"",
            "\"ipv4_port\":\(ipv4?.port ?? 0)",
            "\"ipv6_port\":\(ipv6?.port ?? 0)"
        ].joined(separator: ",")
        print("{\(payload)}")
    } else {
        print("READY mode=network-framework-check ipv4_port=\(ipv4?.port ?? 0) ipv6_port=\(ipv6?.port ?? 0)")
    }
    fflush(stdout)
    while true {
        Thread.sleep(forTimeInterval: 3600)
    }
}

private struct CheckListener {
    var host: String
    var port: UInt16
    var listener: NWListener
}

private final class CheckFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var value: Error? {
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

private func startCheckListeners(port requestedPort: UInt16, queue: DispatchQueue) throws -> [CheckListener] {
    var output: [CheckListener] = []
    let ipv4 = try startCheckListener(host: "127.0.0.1", port: requestedPort, queue: queue)
    output.append(ipv4)
    let ipv6Port = requestedPort == 0 ? ipv4.port : requestedPort
    if let ipv6 = try? startCheckListener(host: "::1", port: ipv6Port, queue: queue) {
        output.append(ipv6)
    }
    return output
}

private func startCheckListener(host: String, port: UInt16, queue: DispatchQueue) throws -> CheckListener {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    let ready = DispatchSemaphore(value: 0)
    let failure = CheckFailureBox()
    listener.newConnectionHandler = { connection in
        connection.start(queue: queue)
        connection.cancel()
    }
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            ready.signal()
        case let .failed(error):
            failure.value = error
            ready.signal()
        default:
            break
        }
    }
    listener.start(queue: queue)
    if ready.wait(timeout: .now() + 5) == .timedOut {
        listener.cancel()
        throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener timed out \(host):\(port)"])
    }
    if let capturedFailure = failure.value {
        listener.cancel()
        throw capturedFailure
    }
    return CheckListener(host: host, port: listener.port?.rawValue ?? port, listener: listener)
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    printUsage()
    exit(0)
}

if CommandLine.arguments.contains("--check") {
    do {
        try runCheckMode()
    } catch {
        fputs("ERROR check \(error)\n", stderr)
        exit(1)
    }
}

private struct ConnectRequest {
    var host: String
    var port: Int32
}

private final class TunnelMetrics: @unchecked Sendable {
    let host: String
    let target: Bool
    private let startedAt = Date()
    private let lock = NSLock()
    private var up = 0
    private var down = 0
    private var closed = false

    init(host: String, target: Bool) {
        self.host = host
        self.target = target
    }

    func add(_ count: Int, up isUp: Bool) {
        lock.lock()
        if isUp {
            up += count
        } else {
            down += count
        }
        lock.unlock()
    }

    func closeLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        closed = true
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        return "CLOSED host=\(host) target=\(target) up_bytes=\(up) down_bytes=\(down) duration_ms=\(ms)"
    }
}

private func parseConnect(_ data: Data) throws -> ConnectRequest {
    guard let text = String(data: data, encoding: .utf8) else {
        throw NSError(domain: "parse", code: 1)
    }
    let line = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").first ?? ""
    let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard parts.count == 3, parts[0] == "CONNECT" else {
        throw NSError(domain: "parse", code: 2)
    }
    let authority = parts[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard authority.count == 2, let port = Int32(authority[1]) else {
        throw NSError(domain: "parse", code: 3)
    }
    return ConnectRequest(host: authority[0], port: port)
}

private func isTargetGoogleAPI(_ host: String, port: Int32) -> Bool {
    guard port == 443 else { return false }
    let normalized = host
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        .lowercased()
    return normalized == "googleapis.com" || normalized.hasSuffix(".googleapis.com")
}

private func sendAll(fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < raw.count {
            let result = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
            if result <= 0 { return }
            sent += result
        }
    }
}

private func connectUpstream(host: String, port: Int32) -> Int32 {
    var hints = addrinfo(
        ai_flags: 0,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let result else {
        return -1
    }
    defer { freeaddrinfo(result) }

    var item: UnsafeMutablePointer<addrinfo>? = result
    while let current = item {
        let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
        if fd >= 0 {
            if connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen) == 0 {
                return fd
            }
            Darwin.close(fd)
        }
        item = current.pointee.ai_next
    }
    return -1
}

private func pipe(from source: Int32, to target: Int32, metrics: TunnelMetrics, up isUp: Bool) {
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = recv(source, &buffer, buffer.count, 0)
        if count <= 0 { break }
        metrics.add(count, up: isUp)
        var sent = 0
        while sent < count {
            let written = buffer.withUnsafeBytes { raw in
                Darwin.send(target, raw.baseAddress!.advanced(by: sent), count - sent, 0)
            }
            if written <= 0 { break }
            sent += written
        }
    }
    shutdown(target, SHUT_WR)
    if let line = metrics.closeLine() {
        print(line)
        fflush(stdout)
    }
}

private func handle(client: Int32) {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.range(of: Data("\r\n\r\n".utf8)) == nil && data.count < 32768 {
        let count = recv(client, &buffer, buffer.count, 0)
        if count <= 0 {
            Darwin.close(client)
            return
        }
        data.append(buffer, count: count)
    }

    guard let request = try? parseConnect(data), request.port == 443 else {
        sendAll(fd: client, Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 9\r\nConnection: close\r\n\r\nForbidden".utf8))
        Darwin.close(client)
        return
    }

    let target = isTargetGoogleAPI(request.host, port: request.port)
    print("CONNECT host=\(request.host):\(request.port) target=\(target)")
    fflush(stdout)

    let upstream = connectUpstream(host: request.host, port: request.port)
    guard upstream >= 0 else {
        sendAll(fd: client, Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 11\r\nConnection: close\r\n\r\nBad Gateway".utf8))
        Darwin.close(client)
        return
    }

    sendAll(fd: client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
    let metrics = TunnelMetrics(host: request.host, target: target)
    let group = DispatchGroup()
    group.enter()
    Thread.detachNewThread {
        pipe(from: client, to: upstream, metrics: metrics, up: true)
        group.leave()
    }
    group.enter()
    Thread.detachNewThread {
        pipe(from: upstream, to: client, metrics: metrics, up: false)
        group.leave()
    }
    group.wait()
    Darwin.close(upstream)
    Darwin.close(client)
}

private func startServer(port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(fd, 128) == 0 else {
        Darwin.close(fd)
        return -1
    }
    return fd
}

let server = startServer(port: 8877)
guard server >= 0 else {
    fputs("ERROR bind 127.0.0.1:8877\n", stderr)
    exit(1)
}

print("READY listen=127.0.0.1:8877 mode=googleapis-monitor")
fflush(stdout)

while true {
    let client = accept(server, nil, nil)
    if client >= 0 {
        Thread.detachNewThread {
            handle(client: client)
        }
    }
}
