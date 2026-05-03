# Implementation Plan: AntigravityPorter

## RALPLAN-DR Summary

### Principles
1. Capture truth before translation: real traffic defines the protocol contract.
2. Fail closed for routed models: never silently send routed traffic to Google.
3. Preserve trust boundaries: auth hosts, non-target hosts, and secrets stay untouched.
4. Make proxy state recoverable: system proxy and certificate changes must be reversible.
5. Keep the architecture testable: parsing, routing, translation, and network I/O stay separated.
6. Stop at protocol uncertainty: no translator work until captured ALPN/HTTP behavior is supported by tests.

### Decision Drivers
1. Behavior parity for native Antigravity daily-driver use.
2. macOS safety around local CA, Keychain, and system proxy state.
3. High-confidence verification from captured real traffic.

### Viable Options
#### Option A: Capture-first native Swift proxy
- Build native proxy, capture pipeline, fixture replay harness, then translators from captured facts.
- Pros: best matches parity requirement; safest against guessed Antigravity schema.
- Cons: slower first visible demo; requires local capture discipline.
- Verdict: chosen.

#### Option B: Schema-first implementation from public/known Gemini shapes
- Build Gemini-style translator first and adapt Antigravity as observed.
- Pros: faster prototype.
- Cons: violates captured-real-traffic proof requirement and risks false confidence.
- Verdict: rejected.

#### Option C: Use an existing proxy core dependency
- Embed a mature MITM/proxy engine and build SwiftUI shell around it.
- Pros: faster low-level proxy maturity.
- Cons: conflicts with native Swift/no-new-dependency preference, increases review/security burden.
- Verdict: rejected initially, but explicitly reopened if Phase 3 captures show HTTP/2 or TLS/proxy behavior that native Swift cannot support within parity requirements.

## ADR
Decision: Implement a native Swift capture-first MITM proxy with a strict allowlist, canonical real-traffic fixtures, and fail-closed routed-model behavior.

Drivers:
- The user requires native Antigravity behavior parity, not partial compatibility.
- Antigravity internal endpoints are not officially documented.
- Local CA and system proxy changes must be recoverable and inspectable.

Alternatives considered:
- Public-schema-first translator: rejected because guessed schemas cannot prove parity.
- Silent Google fallback: rejected because routed model intent must be honored.
- Existing third-party proxy core: rejected initially because security review and native Swift constraints outweigh prototype speed.

Consequences:
- The first milestone is capture/replay infrastructure, not cheaprouter translation.
- Captured fixtures become the contract for implementation.
- Some live behavior may remain unsupported until a capture exists; routed unsupported behavior fails closed.

Follow-ups:
- Reassess third-party TLS/proxy dependencies only if native CONNECT/TLS handling blocks progress.
- Define private fixture retention policy before storing real prompts.
- Confirm exact cheaprouter model list and `/v1/responses` use after captures show what Antigravity requires.

## Architecture

### Modules
- `AppShell`
  - SwiftUI menu-bar app, `MenuBarExtra`, popover navigation, status model.
- `SettingsStore`
  - Non-secret preferences, model route toggles, port, base URL, launch-at-login flag.
- `KeychainStore`
  - cheaprouter API key, CA private key, CA certificate metadata.
- `CertificateAuthority`
  - CA identity generation/loading, DER export, leaf identity creation, trust verification.
- `SystemProxyManager`
  - service discovery, proxy snapshot, enable/disable, bypass exceptions, crash recovery marker.
- `ProxyCore`
  - `NWListener`, CONNECT parser, connection lifecycle, blind tunnel, MITM session handoff. It transports bytes and emits parsed request envelopes; it does not own model routing or schema translation.
- `HostPolicy`
  - target inference hosts, excluded auth/userinfo hosts, cheaprouter self-loop bypass.
- `CapturePipeline`
  - capture mode, sanitizer, fixture writer, timing metadata, replay manifest.
- `RequestClassifier`
  - app/action/model extraction for Gemini and captured Antigravity shapes.
- `RoutingEngine`
  - direct vs cheaprouter decision, endpoint choice, fail-closed policy. It owns route decisions after classification.
- `GooglePassThrough`
  - transparent upstream forwarding for direct models after decrypted classification when needed.
- `CheapRouterClient`
  - outbound requests with proxy bypass, auth header, streaming response handling.
- `Translators`
  - Gemini/Antigravity to cheaprouter request and cheaprouter to Google-compatible response. It owns all schema transformation.
- `ReplayHarness`
  - deterministic fixture replay and parity comparison.
- `RequestLog`
  - sanitized ring buffer and counters.

### Network Flow
1. Client sends `CONNECT host:443`.
2. `HostPolicy` decides:
   - excluded/non-target host: blind tunnel bytes to original host.
   - target inference host: accept CONNECT and start local TLS with host leaf identity.
3. Parse decrypted HTTP request.
4. Extract app/action/model from URL/body.
5. If model is direct: forward decrypted request to original Google host and relay response shape unchanged. Direct target inference traffic is decrypted for classification because model routing requires body/path inspection; it is not captured or logged unless capture mode is explicitly enabled.
6. If model is routed:
   - translate to cheaprouter request.
   - call cheaprouter with `Authorization: Bearer`.
   - translate response/SSE back.
   - if unsupported: return compatible fail-closed error.

### Important Design Choices
- Add `cheaprouter.uk` and auth hosts to proxy bypass/exceptions to avoid loops and token interception.
- Use capture mode before route mode. Route toggles for uncaptured Antigravity variants stay disabled or fail closed.
- Store private fixture packs outside the repo by default; commit only sanitized fixtures.
- Implement HTTP/1.1 first only if captures prove clients use it. If captures show HTTP/2, stop before translation and either add tested HTTP/2 frame/header/SSE handling or reopen the dependency-backed proxy-core option.
- Treat `/v1/responses` as capture-driven. The initial route rule remains Claude -> `/v1/messages`, non-Claude -> `/v1/chat/completions` unless captured behavior proves Responses semantics are required.

## Safety Matrices

### System Proxy Restore Matrix
- Per-service snapshot records secure web proxy enabled state, host, port, bypass list, and service enabled/disabled state.
- Enable mutates only active services selected by the app; disabled services are recorded but not enabled.
- If enable fails midway, already-mutated services roll back to their original snapshot.
- If restore fails for any service, the original snapshot is retained and the UI shows exact `networksetup` recovery commands.
- Existing user proxy settings are preserved and restored exactly; AntigravityPorter does not assume previous proxy state was empty.
- Crash marker contains snapshot ID, app port, affected services, and timestamp. On relaunch, stale markers force a recovery banner before enabling routing.

### CA Trust / Rotation Matrix
- CA private key remains in Keychain; certificate DER may be exported for user trust.
- Trust installation is manual/guided unless macOS prompts for user/admin auth through documented APIs.
- CA rotation clears all in-memory leaf identities and marks old CA cleanup pending.
- Uninstall flow removes app-owned Keychain identities where permitted and instructs the user how to remove trusted CA entries that require Keychain Access/admin action.
- Excluded hosts are asserted to never call leaf generation.

### Direct-Model Privacy Boundary
- Target inference requests must be MITM-decrypted for classification if model selection is only visible inside body/path.
- Outside explicit capture mode, direct-model bodies are streamed onward and discarded after classification.
- Logs store only timestamp, app, host, action, model, route, status, latency, and sanitized error reason.

## Implementation Phases

### Phase 0: Project Scaffold
- Create Xcode/SwiftPM project for macOS 14 app.
- Set Apple Silicon deployment assumptions and app metadata.
- Add test targets for unit and integration tests.
- Add minimal menu-bar shell with disabled status tabs.
- Verification: app builds and launches menu-bar icon.

### Phase 1: Safety Foundation
- Implement `SettingsStore`, `KeychainStore`, `RequestLog`.
- Implement `HostPolicy` with target and excluded hosts.
- Implement `SystemProxyManager` snapshot/restore with dry-run tests.
- Add crash/relaunch marker for stale proxy state recovery.
- Verification: unit tests for host policy, secret redaction, and proxy state serialization.

### Phase 2: Certificate Authority
- Generate CA key/cert on first launch.
- Store CA private key and metadata in Keychain.
- Export CA cert for manual trust install.
- Verify trust status and show guided UI.
- Generate per-host leaf identities and cache in memory.
- Verification: unit/integration tests for CA reuse, leaf SAN, trust status detection, and CA rotation.

### Phase 3: Proxy Core
- Build `NWListener` on configurable loopback port.
- Parse CONNECT requests.
- Implement blind tunnel for excluded and non-target hosts.
- Implement target-host TLS termination.
- Record ALPN and HTTP protocol for captured Antigravity/Gemini sessions.
- Add lifecycle cancellation and connection cleanup.
- Verification: local TLS client integration tests; excluded hosts are not decrypted; protocol gate documents HTTP/1.1 vs HTTP/2 support before Phase 4/6 translation work.

### Phase 4: Capture Pipeline
- Add capture mode for target inference hosts while models are still direct.
- Record sanitized request/response/timing fixtures.
- Build fixture manifest and sanitizer.
- Add replay harness skeleton.
- Verification: capture a real Gemini CLI workflow and one Antigravity workflow; sanitizer passes.

### Phase 5: Classification and Routing
- Implement Gemini URL model/action extraction.
- Implement Antigravity captured-shape model/action extraction.
- Implement route toggles and seen-model discovery.
- Unknown models default direct.
- Routed unknown/unsupported captured variants fail closed.
- Verification: fixture replay tests for all captured request classifiers.

### Phase 6: cheaprouter Translation
- Implement cheaprouter request builders:
  - Claude-like models -> `/v1/messages`.
  - Other models -> `/v1/chat/completions`, unless captures require `/v1/responses`.
- Implement streaming and non-streaming response translators.
- Implement `countTokens` parity from captures; do not fake exactness unless capture-derived tolerance allows it.
- Verification: fake cheaprouter integration tests and fixture replay comparison.

### Phase 7: UI Completion
- Status tab: proxy toggle, CA trust, cheaprouter reachability, counters.
- Models tab: known/seen models, route toggles, unsupported state, manual add.
- Settings tab: base URL, API key, port, launch at login, install CA.
- Log tab: last 50 sanitized request events.
- Verification: UI state tests and manual smoke on macOS.

### Phase 8: Live Parity Validation
- Run Antigravity and Gemini CLI with Google direct capture.
- Run same workflows routed through cheaprouter.
- Compare client-visible behavior and logs.
- Fix translators until captured parity passes or fail-closed behavior is validated.
- Verification: completed e2e checklist and replay suite.

### Phase 9: Packaging and Recovery
- Add launch-at-login via `SMAppService`.
- Add app quit/relaunch recovery for proxy and cert state.
- Create local distribution build notes.
- Verification: fresh-machine install checklist and recovery checklist.

## Pre-Mortem
1. Antigravity uses HTTP/2 or certificate pinning, so HTTP/1.1 MITM cannot observe usable request bodies.
   - Mitigation: make capture/proxy protocol detection Phase 3 gate; stop translation work until proven; reopen dependency-backed proxy core if native support is not viable.
2. System proxy restore fails and disrupts user network traffic.
   - Mitigation: snapshot before enable, bypass list, stale marker, explicit restore button, `networksetup` recovery command in UI/log.
3. Captured Antigravity behavior includes provider features cheaprouter cannot reproduce.
   - Mitigation: fail closed per request, surface unsupported capability by model/action, do not mark model routeable until fixture replay passes.

## Follow-Up Staffing Guidance

### Sequential `$ralph`
Use `$ralph .omx/plans/implementation-plan-antigravityporter.md` after PRD/test spec approval. Recommended lane order: scaffold -> safety -> CA -> proxy core -> capture -> classification -> translation -> UI -> parity.

### Parallel `$team`
Use team only after Phase 0 scaffold defines module boundaries. Suggested lanes:
- `swift-expert`: app shell, Keychain, certificate, SMAppService.
- `backend-developer` or `fullstack-developer`: proxy core, CONNECT, tunnels, outbound clients.
- `test-automator`: fixture/replay harness and integration tests.
- `security-reviewer`: CA trust, host policy, secret redaction, proxy bypass review.
- `qa-expert`: live parity checklist and release gates.

Team verification path:
1. Module owner tests pass.
2. Integration proxy tests pass.
3. Fixture replay suite passes.
4. Security reviewer signs off on trust/auth boundaries.
5. Lead runs live e2e checklist on macOS.

## Suggested Reasoning Levels
- CA/proxy/security lanes: high.
- Translator/replay parity lanes: high.
- UI/settings lanes: medium.
- Styling/logging cleanup: low to medium.

## External References
- Apple Network framework: https://developer.apple.com/documentation/network
- Apple Security/Keychain: https://developer.apple.com/documentation/security/keychain-services
- Apple ServiceManagement `SMAppService`: https://developer.apple.com/documentation/servicemanagement/smappservice
- Apple SystemConfiguration: https://developer.apple.com/documentation/systemconfiguration
- Gemini API reference: https://ai.google.dev/api
- Gemini generate content: https://ai.google.dev/api/generate-content
- Gemini token counting: https://ai.google.dev/api/tokens
