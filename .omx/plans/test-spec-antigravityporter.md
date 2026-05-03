# Test Spec: AntigravityPorter

## Metadata
- Date: 2026-05-03T17:17:24Z
- Source PRD: `.omx/plans/prd-antigravityporter.md`
- Source requirements: `.omx/specs/deep-interview-antigravityporter.md`

## Test Strategy
Use a capture-first test pyramid:
- Unit tests for parsers, routers, certificate cache logic, Keychain wrappers, and schema translation.
- Fixture replay tests generated only from real Google-backed captures.
- Proxy integration tests with local TLS clients and fake upstream servers.
- Live manual/e2e tests against Antigravity and Gemini CLI on macOS.
- Recovery/security tests around system proxy state, certificate trust state, and log redaction.

## Canonical Fixture Policy
- Captures from real Antigravity/Gemini CLI Google-backed traffic are canonical.
- Synthetic fixtures may test internal error paths, but they cannot count as parity proof.
- Fixtures must be sanitized before commit: remove OAuth tokens, API keys, user secrets, cookies, machine identifiers, and prompt contents unless intentionally retained in a private local fixture pack.
- Each fixture records:
  - client app (`antigravity` or `gemini-cli`)
  - host/path/action
  - model
  - request headers after sensitive redaction
  - raw request body
  - raw response headers
  - raw response body or SSE event stream
  - timings needed for streaming cadence comparison
  - route expectation
  - parity tolerances derived from observed behavior

## Unit Tests
- `HostPolicyTests`
  - Target hosts match only allowed inference endpoints.
  - OAuth/userinfo hosts are always blind tunnel.
  - cheaprouter host bypasses local proxy to prevent loops.
- `ConnectParserTests`
  - CONNECT target parsing accepts valid host/port and rejects malformed input.
  - Proxy headers are stripped before upstream forwarding.
- `ModelExtractorTests`
  - Gemini model extracted from `/v1beta/models/{modelId}:action`.
  - Antigravity model extracted from top-level and nested captured paths.
  - Unknown extraction for routed request yields fail-closed error.
- `RoutingDecisionTests`
  - Unknown model defaults to Google direct.
  - User-routed model chooses cheaprouter endpoint.
  - Claude-like models choose `/v1/messages`.
  - Non-Claude models choose `/v1/chat/completions` unless captured evidence proves `/v1/responses` is required.
- `CertificateAuthorityTests`
  - CA identity created once and reused.
  - Leaf cert SAN matches intercepted hostname.
  - Leaf cache is keyed by hostname and invalidated on CA rotation.
  - CA rotation clears old leaf cache and exposes stale-trust cleanup status.
  - CA uninstall removes app-owned Keychain identity material where permitted.
  - CA uninstall preserves manual remediation instructions when trusted-CA removal requires Keychain Access or admin action.
  - No stale app-generated leaf identity can be reused after uninstall or rotation.
  - UI/status model exposes `trusted`, `untrusted`, `cleanup pending`, and `rotation pending` states.
  - Excluded hosts never request or receive generated leaf identities.
- `KeychainStoreTests`
  - API key and CA key are stored/retrieved via Keychain wrappers.
  - No secret appears in preferences/log serialization.
- `TranslatorTests`
  - Captured Gemini/Antigravity request maps to cheaprouter payload.
  - cheaprouter response maps back to captured-compatible Google response shape.
  - Unsupported fields fail closed when parity cannot be maintained.
- `SSETranslatorTests`
  - Event boundaries, final events, error events, and timing metadata are preserved within tolerance.
- `SystemProxyStateTests`
  - Snapshot/restore logic handles Wi-Fi, Ethernet, multiple services, disabled services, and app crash markers.
  - Existing user proxy settings are preserved and restored exactly.
  - Partial enable failure rolls back already-mutated services.
  - Partial restore failure produces a recovery action and does not overwrite the original snapshot.
  - `networksetup` recovery command generation is covered for each affected service.

## Integration Tests
- Local proxy accepts CONNECT and returns 200 for target hosts.
- Excluded hosts are blind tunneled without TLS termination.
- Target inference host receives locally generated leaf cert signed by AntigravityPorter CA.
- ALPN negotiation is recorded in test fixtures; HTTP/1.1 and HTTP/2 paths are separated.
- If a client negotiates HTTP/2, frame/header handling tests must pass before translator work proceeds.
- Fake Google upstream receives byte-identical pass-through for unselected models.
- Fake cheaprouter receives translated requests with `Authorization: Bearer <key>`.
- Fake cheaprouter errors produce Antigravity-compatible fail-closed responses.
- URLSession outbound clients bypass system proxy for cheaprouter and upstream Google calls.
- Request log ring buffer records last 50 events without secrets.

## Fixture Replay Tests
- Replay captured Antigravity streaming inference.
- Replay captured Antigravity non-streaming inference.
- Replay captured Antigravity `countTokens`.
- Replay captured Gemini CLI streaming inference.
- Replay captured Gemini CLI non-streaming inference.
- Replay captured Gemini CLI `countTokens`.
- Replay captured tool/file/image/citation/safety variants if present in captures.
- Compare output shape and required client-visible fields against capture-derived expectations.

## Live Manual/E2E Tests
- Fresh install: launch app, create CA, install/trust CA, verify trust status.
- Enable proxy and verify macOS HTTPS proxy points to configured local port.
- Antigravity with all models direct: works through blind/pass-through path.
- Gemini CLI with all models direct: works through blind/pass-through path.
- Route one cheaprouter-capable model: Antigravity streaming request succeeds.
- Route one cheaprouter-capable model: Antigravity non-streaming request succeeds.
- Route one cheaprouter-capable model: Antigravity token count succeeds.
- Route one cheaprouter-capable model: Gemini CLI streaming request succeeds.
- Route one cheaprouter-capable model: Gemini CLI non-streaming request succeeds.
- Force unsupported request for routed model: fail-closed compatible error appears in client and log.
- Disable proxy: original system proxy settings restored.
- Force quit while enabled, relaunch: app detects stale enabled marker and offers/executes restore.

## Security Tests
- No OAuth tokens or Google auth headers are logged.
- No cheaprouter API key is logged.
- No private key material leaves Keychain APIs.
- Captures are blocked from export/commit until sanitizer passes.
- Hosts outside target inference allowlist are never MITM-terminated.
- Direct-model target inference traffic is decrypted only for classification unless explicit capture mode is enabled.
- Direct-model request bodies are not persisted or logged outside capture mode.
- CA uninstall/rotation cleanup removes app-owned Keychain material where allowed, invalidates all old leaf identities, and surfaces manual trusted-CA cleanup when macOS requires user/admin action.

## Observability Checks
- Status tab shows proxy on/off, CA trust state, cheaprouter reachability, and request counters.
- Models tab shows known, seen, routed, direct, and unsupported models.
- Log tab shows timestamp, app, model, route, action, status, latency, and sanitized failure reason.
- Internal debug mode can export sanitized diagnostic bundle.

## Exit Criteria
- All unit tests pass.
- All proxy integration tests pass.
- ALPN/protocol gate has a documented PASS result for captured Antigravity and Gemini CLI workflows.
- Fixture replay suite passes for the captured v1 workflow pack.
- Manual/e2e checklist passes on an Apple Silicon macOS 14+ machine.
- Recovery checklist passes for disable, forced kill, relaunch, and CA rotation.
- CA uninstall/rotation/trust cleanup checklist passes.
