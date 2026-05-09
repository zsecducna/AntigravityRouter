import Foundation

// MARK: - ConnectionSignal

/// The parsed signal extracted from the first bytes of an inbound TCP connection.
/// Used by `ConnectionRoutingMatrix` to produce a `ConnectionRoutingDecision`.
public enum ConnectionSignal: Equatable, Sendable {
    /// A TLS ClientHello was received directly (transparent proxy / direct TLS mode).
    case tlsClientHello(info: ClientHelloInfo)
    /// An HTTP CONNECT request was received naming `host:port`.
    case connectRequest(host: String, port: UInt16)
    /// A plain HTTP request (GET/POST/…) was received; used for PAC and direct HTTP.
    case httpRequest(method: String, path: String, host: String?)
    /// Bytes received but structurally unrecognisable.
    case malformed
}

// MARK: - ConnectionRoutingDecision

/// TCP-connection-level routing decision produced by `ConnectionRoutingMatrix`.
///
/// Distinct from `RoutingDecision` (HTTP/AI-model level) in `Translators.swift`.
public enum ConnectionRoutingDecision: Equatable, Sendable {
    /// Received raw TLS; terminate and handle as direct HTTPS.
    case directTLS
    /// CONNECT to an interceptable host; perform MITM TLS termination.
    case connectMITM(host: String)
    /// CONNECT to a non-interceptable host; tunnel opaquely.
    case blindTunnel
    /// Reject and close; reason is logged.
    case reject(reason: String)
    /// Plain HTTP request for the PAC script endpoint.
    case pacRequest
    /// Route the decrypted HTTP request through CheapRouter.
    case cheapRouter
    /// Route the decrypted HTTP request directly to Google upstream.
    case googleDirect
}

// MARK: - ConnectionRoutingMatrix

/// Maps a `ConnectionSignal` plus host-policy decisions to a `ConnectionRoutingDecision`.
///
/// All seven routing variants are covered:
/// - `directTLS`     — raw TLS ClientHello on interceptable host
/// - `connectMITM`   — CONNECT to target-inference host
/// - `blindTunnel`   — CONNECT to non-interceptable host
/// - `reject`        — CONNECT to non-443 port or unsupported protocol
/// - `pacRequest`    — plain HTTP GET /proxy.pac (or /wpad.dat)
/// - `cheapRouter`   — plain HTTP whose host/path routes via CheapRouter
/// - `googleDirect`  — plain HTTP whose host/path goes directly to Google
public struct ConnectionRoutingMatrix: Sendable {

    public var hostPolicy: HostPolicy
    public var connectTargetPolicy: ConnectTargetPolicy

    public init(
        hostPolicy: HostPolicy = .default,
        connectTargetPolicy: ConnectTargetPolicy = .default
    ) {
        self.hostPolicy = hostPolicy
        self.connectTargetPolicy = connectTargetPolicy
    }

    public func decision(for signal: ConnectionSignal) -> ConnectionRoutingDecision {
        switch signal {

        case let .tlsClientHello(info):
            let host = info.sni ?? ""
            // We don't know the path yet at TLS level; defer to directTLS.
            // HostPolicy path-level decisions are applied post-TLS.
            let hostDecision = hostPolicy.decision(for: host, port: 443, path: nil)
            switch hostDecision {
            case .intercept:
                return .directTLS
            case .blindTunnel:
                return .directTLS // still directTLS; post-TLS gate decides intercept vs tunnel
            }

        case let .connectRequest(host, port):
            let targetDecision = connectTargetPolicy.decision(for: host, port: Int(port))
            switch targetDecision {
            case .reject:
                return .reject(reason: "CONNECT to port \(port) not permitted")
            case .targetInference:
                return .connectMITM(host: host)
            case .blindTunnel:
                return .blindTunnel
            }

        case let .httpRequest(method, path, host):
            // PAC script requests
            if method == "GET",
               path == "/proxy.pac" || path == "/wpad.dat" || path.hasSuffix("/proxy.pac") {
                return .pacRequest
            }
            // Route based on host policy (path known for HTTP)
            let normalizedHost = (host ?? "").lowercased()
            let hostDecision = hostPolicy.decision(for: normalizedHost, port: 443, path: path)
            switch hostDecision {
            case .intercept:
                // HTTP request to an inference host — determine downstream target
                if isCheapRouterTarget(host: normalizedHost) {
                    return .cheapRouter
                }
                return .googleDirect
            case .blindTunnel:
                return .reject(reason: "plain HTTP to non-interceptable host \(normalizedHost)")
            }

        case .malformed:
            return .reject(reason: "malformed initial bytes")
        }
    }

    // MARK: - Private

    private func isCheapRouterTarget(host: String) -> Bool {
        host.contains("cheaprouter")
    }
}
