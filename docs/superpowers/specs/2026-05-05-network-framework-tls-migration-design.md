# Network.framework TLS Migration Design

**Date:** 2026-05-05
**Scope:** Replace SecureTransport (`SSLContext`) with Network.framework (`NWListener`/`NWConnection`) in `SocketProxyServer` → `NWProxyServer`
**Root cause fixed:** SecureTransport ALPN negotiation broken → LS not connecting

---

## Problem

`SocketProxyServer` in `PorterRuntimeController.swift` uses deprecated SecureTransport APIs (`SSLCreateContext`, `SSLHandshake`, `SSLRead`, `SSLWrite`, `SSLSetALPNProtocols`, `SSLCopyALPNProtocols`). ALPN negotiation is broken, causing Language Server clients to fail TLS handshake. Swift has no `#pragma`-equivalent to suppress these warnings.

---

## Architecture

```
PorterRuntimeController
└── NWProxyServer (actor)                    ← replaces SocketProxyServer (class)
    ├── primaryListener: NWListener          ← plain TCP, configured host:port
    ├── tlsTerminationServer: TLSTerminationServer  ← NWListener, loopback + TLS
    └── per-connection: Task {
            ProxyConnectionHandler (actor)
            ├── peek initial bytes (receive up to 16KB)
            ├── direct TLS (ClientHello) → handleMITM(sendConnectResponse: false)
            ├── CONNECT request →
            │   case targetInference → handleMITM(sendConnectResponse: true)
            │   case blindTunnel    → handleBlindTunnel
            │   case reject         → 403 Forbidden, close
            ├── PAC request → serve PAC script, close
            └── unknown     → 400 Bad Request, close
        }
```

### CONNECT+TLS constraint

`NWConnection` is immutable — TLS cannot be added after plaintext CONNECT exchange. This is fundamental to Network.framework. **Solution:** `TLSTerminationServer` — a second `NWListener` on an ephemeral loopback port (`127.0.0.1:0`, OS assigns port) with TLS configured. After sending `200 Connection Established`, raw bytes from `clientConn` are relayed into a new plain `NWConnection` to that loopback port. `TLSTerminationServer` accepts that connection with TLS, decrypts, and gives plaintext HTTP to `ProxyConnectionHandler`.

---

## Components

### `NWProxyServer` (actor)

- `init(host:port:certificateAuthority:keychainStore:eventSink:pacScriptProvider:)`
- `func start() async throws` — creates `NWListener` on `NWParameters.tcp`, binds `primaryListener`, starts `TLSTerminationServer`
- `func stop()` — cancels all listeners and running connection tasks
- Each accepted `NWConnection` → `Task { await ProxyConnectionHandler(...).run() }`; tasks stored for cancellation on stop
- Replaces `SocketProxyServer` class in `PorterRuntimeController.swift`; `PorterRuntimeController` public API unchanged

### `TLSTerminationServer` (actor)

- Single `NWListener` on `127.0.0.1:0` (ephemeral); `port` property exposes assigned port after start
- `NWParameters` built with `NWProtocolTLS.Options`:
  - `sec_protocol_options_add_tls_application_protocol(opts, "http/1.1")` ← **ALPN fix**
  - `sec_protocol_options_set_local_identity(opts, secIdentity)` ← per-host cert
- `func requestConnection(for host: String) async throws -> NWConnection` — configures identity for host, enqueues expectation, returns next accepted `NWConnection`
- One instance shared across all MITM connections

### `ProxyConnectionHandler` (actor)

- `func run() async` — top-level connection lifetime
- `peek()` → `conn.receive(minimumIncompleteLength: 1, maximumLength: 16384)` wrapped in `withCheckedContinuation`
- `handleBlindTunnel(upstream: NWConnection)` → `withThrowingTaskGroup` with two children: `pump(from: client, to: upstream)` and reverse
- `handleMITM(host:sendConnectResponse:)`:
  1. Optionally write `"HTTP/1.1 200 Connection Established\r\n\r\n"` on `clientConn`
  2. Obtain loopback port from `tlsTermServer.port`
  3. Create `relayConn = NWConnection(host: "127.0.0.1", port: loopbackPort, using: .tcp)`
  4. Call `tlsTermServer.requestConnection(for: host)` → `tlsConn: NWConnection` (TLS)
  5. `TaskGroup`: pump `clientConn ↔ relayConn` (raw bytes, bidirectional)
  6. `tlsConn.receive()` → plaintext HTTP → parse → route upstream → write response

### Unchanged

- `CertificateAuthority`, `KeychainStore`
- `HTTPRequestParser`, `ConnectRequestParser`, `TLSClientHelloParser`
- `HostPolicy`, `ConnectTargetPolicy`, `ProxyProtocolGate`
- HTTP routing, translation, `Translators`
- `PorterRuntimeController` public interface (`start`, `stop`, `status`)

---

## Concurrency Model

- **Swift 6 strict concurrency** throughout (`Sendable`, `actor` isolation)
- `NWConnection` callbacks bridged to `async` via `withCheckedContinuation` / `withCheckedThrowingContinuation`
- Timeouts: `withThrowingTaskGroup` + child task cancellation after deadline
- Per-connection `Task` handles cancelled/failed connections independently; failure does not affect other connections
- `NWListener` runs on its own internal queue; actor isolation prevents data races on `NWProxyServer` state

---

## Error Handling

| Error source | Handling |
|---|---|
| `NWListener` start failure | Propagates through `NWProxyServer.start()` → `PorterRuntimeController` → `status.lastError` |
| `NWError` on connection | Map to `PorterRuntimeError` (`.socketFailed`, `.tlsFailed`), `eventSink(.failed(...))`, connection closed |
| TLS handshake failure | `NWConnection` state `.failed(error)` → caught in `withCheckedThrowingContinuation`, logged, closed |
| `TLSTerminationServer` relay timeout | Cancel MITM task, close `clientConn` |
| HTTP parse error | 400 response on `tlsConn`, close |

---

## Testing

**Existing** (no changes): All unit tests for parsers, routing, CA, policy — unchanged.

**New integration test** (`NWProxyServerTests`):
- Start `NWProxyServer` on port 0 (ephemeral)
- `URLSession` configured with proxy to loopback port
- Issue `CONNECT` to `127.0.0.1` (a `targetInference` host)
- Assert: TLS handshake succeeds, ALPN negotiated as `"http/1.1"`

**New unit test** (`TLSTerminationServerTests`):
- Verify `sec_protocol_options` sets correct ALPN protocol before accepting
- Verify per-host `SecIdentity` is applied to `NWProtocolTLS.Options`

---

## Files Modified

| File | Change |
|---|---|
| `Sources/AntigravityRouterApp/PorterRuntimeController.swift` | Replace `SocketProxyServer` class with `NWProxyServer` actor + `TLSTerminationServer` actor + `ProxyConnectionHandler` actor |
| `Tests/AntigravityRouterCoreTests/ProxyCoreTests.swift` | Add integration test for ALPN via `NWProxyServer` |

**No changes to `Package.swift`** — Network.framework auto-linked on macOS.

---

## Spec Self-Review

- No TBDs or placeholders
- Architecture matches component descriptions
- CONNECT+TLS constraint acknowledged and resolved
- Scope: single file replacement + one new test file — fits one implementation plan
- ALPN fix mechanism explicit (`sec_protocol_options_add_tls_application_protocol`)
