# PRD: AntigravityPorter

## Metadata
- Date: 2026-05-03T17:17:24Z
- Source spec: `.omx/specs/deep-interview-antigravityporter.md`
- Context snapshot: `.omx/context/antigravityporter-20260503T164715Z.md`
- Planning mode: `$ralplan --consensus`, deliberate mode
- Product target: macOS 14+, Apple Silicon only, native Swift/SwiftUI, menu-bar only

## Goal
Build `AntigravityPorter`, a local trusted HTTPS proxy that lets Google Antigravity and Gemini CLI keep their native workflows while selected model traffic is executed through `cheaprouter.uk`.

## Non-Negotiable V1 Definition
V1 is not a demo adapter. V1 is daily-driver behavior parity for captured real Antigravity and Gemini CLI workflows.

Behavior parity means the client cannot distinguish Google-backed use from proxied cheaprouter use for captured workflows, including:
- Streaming cadence and chunk shape.
- Non-streaming response shape.
- `countTokens` behavior.
- Error shape and failure timing.
- Token accounting fields used by the clients.
- Text, tool, file, image, citation, safety, finish-reason, and unknown fields present in real captures.
- Client UI behavior.

The canonical evidence source is captured real traffic only. Guessed schemas may guide implementation, but they cannot satisfy acceptance.

## Users
- Primary user: owner/operator who uses Google Antigravity and Gemini CLI and wants selected models routed through cheaprouter.
- Secondary user: future technical user willing to install/trust a local CA and run a menu-bar utility.

## In Scope
- Native macOS menu-bar app with Status, Models, Settings, and Log tabs.
- Local HTTP/HTTPS proxy on `127.0.0.1:8877`, configurable.
- System HTTPS proxy enable/disable and restore.
- CONNECT handling for Google inference hosts.
- TLS termination only for allowed inference endpoints.
- Blind CONNECT tunnel pass-through for excluded auth/userinfo hosts and all non-target hosts.
- Local CA creation, Keychain storage, manual trust install flow, and trust verification.
- CA rotation, uninstall guidance, and cleanup state tracking.
- Per-host leaf certificate generation and in-memory identity cache.
- Capture mode for Google-backed traffic to generate canonical fixtures.
- Replay/regression harness from captured fixtures.
- Translation from captured Antigravity/Gemini request shapes to cheaprouter-compatible requests.
- Translation from cheaprouter responses back to captured Google-compatible client response shapes.
- Per-model routing controls, seen-model discovery, and fail-closed behavior for routed models.
- cheaprouter API key and CA private key stored in Keychain.
- Last-50 request log with route, model, action, status, latency, and failure reason.

## Out of Scope
- Silent fallback to Google for routed models.
- Passing acceptance from guessed or public-only schema fixtures.
- App Store sandbox distribution in v1.
- Multi-account cheaprouter auth.
- Per-model API key overrides.
- Conversation history storage beyond transient request handling and test fixtures.
- Automatic admin-bypassing certificate trust.

## Product Stories
1. As a user, I can enable/disable the proxy from the menu bar and see whether traffic is active.
2. As a user, I can install and trust the AntigravityPorter CA using guided steps and see verification status.
3. As a user, I can route specific models through cheaprouter while unknown models default to Google direct.
4. As a user, I can capture real Google-backed Antigravity/Gemini workflows before routing them.
5. As a user, I can replay captured workflows through the local translator and compare outputs.
6. As a user, routed unsupported requests fail closed with a clear compatible error instead of silently hitting Google.
7. As a user, auth-sensitive Google hosts are never decrypted or modified.
8. As a user, system proxy settings are restored cleanly on disable, crash recovery, and app relaunch.

## Acceptance Criteria
- Captured real Antigravity workflows pass end-to-end through AntigravityPorter for routed models.
- Captured real Gemini CLI workflows pass end-to-end through AntigravityPorter for routed models.
- Capture fixtures are generated from Google-backed traffic and stored in a sanitized fixture format.
- Replay harness verifies request extraction, routing decisions, translations, response shape, streaming events, and fail-closed errors.
- Excluded hosts (`oauth2.googleapis.com`, `accounts.google.com`, `www.googleapis.com`) are blind tunneled and never TLS-terminated.
- All non-target hosts are blind tunneled.
- cheaprouter requests never loop through the local system proxy.
- System proxy restore is covered by tests and manual recovery UX.
- Secrets are stored in Keychain, not plaintext preferences.
- The UI exposes route state, reachability, certificate trust status, and recent request logs.
- Direct-model inference requests to target inference hosts may be decrypted only long enough to classify model/action and forward to Google. They are not captured or logged unless capture mode is explicitly enabled.
- ALPN/protocol capture records whether clients negotiate HTTP/1.1 or HTTP/2. Translation work cannot proceed until the negotiated protocol is supported by tests or a dependency exception is approved.
- CA uninstall/rotation leaves no stale app-generated leaf identities in memory and gives the user a clear path to remove the trusted CA from Keychain.

## Official-Source Constraints
- Apple `Network.framework` supports listener/connection primitives for local proxying.
- Apple `Security` and Keychain APIs cover key/certificate storage and app-local trust evaluation.
- Modifying trust settings may require user/admin authentication; v1 should guide and verify trust, not promise silent installation.
- `SMAppService` is the current macOS launch-at-login path.
- `SystemConfiguration`/CFNetwork proxy APIs exist, but implementation should retain a `networksetup` fallback for local development recovery.
- Gemini REST has official `generateContent`, `streamGenerateContent`, and `countTokens` docs.
- Antigravity Cloud Code internal endpoint shape is not official; capture-driven planning is mandatory.

## Primary Risks
- Antigravity may use HTTP/2, gRPC-like framing, certificate pinning, or internal schemas that change.
- System proxy changes affect all apps unless scoped with bypass rules and restore safeguards.
- Local CA handling is high-risk; a bad implementation can weaken user trust boundaries.
- Behavior parity can only be proven for captured workflows, not unknown future internal endpoint changes.
- cheaprouter target models may not support every Google/Antigravity behavior; fail-closed UX must be good enough for diagnosis.

## Release Gates
1. Capture gate: real Google-backed fixture pack exists.
2. Safety gate: pass-through/excluded host behavior is proven before MITM routing is enabled.
3. Protocol gate: ALPN/HTTP protocol behavior from captures is supported by proxy tests; otherwise planning stops for dependency/protocol review.
4. Translation gate: replay tests pass for captured workflows.
5. Integration gate: live Antigravity/Gemini workflows pass on a local Mac.
6. Recovery gate: proxy disable/restore works after normal exit, forced kill, relaunch, partial service failure, and prior user proxy preservation.
7. Security gate: no secret leakage in logs, fixtures, preferences, or crash output.
