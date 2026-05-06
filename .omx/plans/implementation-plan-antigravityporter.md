# Implementation Plan: AntigravityPorter Routing-Safety Pivot

## Status
- Updated: 2026-05-05T00:00:00Z
- Supersedes: previous global Secure Web Proxy and PAC-first plans.
- Planning mode: `$ralplan --consensus --deliberate`
- Context snapshot: `.omx/context/antigravityporter-routing-pivot-20260504T012359Z.md`

## Live Routing Correction
PAC/domain routing is no longer the default implementation path. Live testing proved
Antigravity's `language_server_macos_arm` opens direct `:443` sockets and ignores the
macOS PAC path for model traffic.

Scope correction: V1 now targets Antigravity only. Gemini CLI is explicitly out of
active routing/interception scope.

V1 default now:

1. Start a local listener on `127.0.0.1:8877`.
2. Do not mutate macOS Secure Web Proxy or Auto Proxy settings in normal mode.
3. Launch Antigravity from AntigravityPorter with `HTTP_PROXY`, `HTTPS_PROXY`,
   `ALL_PROXY`, and lowercase equivalents pointed at the local listener.
4. Blind-tunnel all HTTPS CONNECT targets by default, while logging known inference
   hosts for later MITM/translation.
5. Keep PAC code/tests as diagnostic fallback only, not the user-facing default.

Live evidence after this correction:

- `scutil --proxy` remains `HTTPSEnable: 0` and `ProxyAutoConfigEnable: 0`.
- Explicit `curl --proxy http://127.0.0.1:8877` succeeds for CloudCode and generic HTTPS.
- Env-launched Antigravity opens `language_server_macos_arm -> 127.0.0.1:8877`.
- Latest Antigravity auth reaches `signedIn`; earlier `socket hang up` was fixed by
  forwarding final `NWConnection.receive` bytes before tunnel close.

## Requirements Summary
AntigravityPorter must continue toward native Antigravity cheaprouter routing, but the network-routing foundation changes:

1. Stop using global all-HTTPS Secure Web Proxy as the default enable path.
2. V1 must use listener-only app-env routing for Antigravity; no normal-mode macOS proxy mutation.
3. The local proxy must never hang indefinitely. Every accept, CONNECT parse, upstream dial, TLS handshake, relay, and translation path needs bounded timeout and deterministic close/error behavior.
4. Logs must appear as soon as target CONNECT traffic reaches the app, before translation is complete.
5. Current model-management and CA-install UI improvements stay in scope.
6. Network Extension Transparent Proxy is the correct long-term architecture, but it becomes a later gated phase because it needs entitlements, extension packaging, and system approval.
7. `NEAppProxyProvider` is not the default path because Apple documents it as entitlement-gated and tied to managed app-layer/per-app VPN configuration.

## RALPLAN-DR Summary

### Principles
1. Do not break the user's Mac internet to test app routing.
2. Route the smallest possible traffic set into the local proxy.
3. Fail fast and visibly; never hang client traffic.
4. Preserve Antigravity-native support and capture-first parity.
5. Separate routing substrate from MITM/translation logic.

### Decision Drivers
1. Safety after live system-wide internet blockage.
2. Fast path to Antigravity CONNECT/log visibility without Network Extension entitlement delay.
3. Future-proof path toward destination-scoped routing with macOS-supported primitives.

### Viable Options

#### Option A: PAC Domain-Scoped Local Proxy for V1, Transparent Proxy Later
- Configure auto proxy selection with a PAC file/script returning `PROXY 127.0.0.1:8877` only for known Google inference hosts, `DIRECT` for everything else.
- Pros:
  - Avoids whole-system HTTPS breakage.
  - Keeps implementation entitlement-free for current SwiftPM/menu-bar app.
  - Lets logs prove Antigravity target CONNECTs are reaching app.
  - Simple recovery: disable Auto Proxy / remove PAC setting.
- Cons:
  - Still system-level by destination domain, not per-app.
  - PAC matching can only use host reliably; path/model classification still happens after CONNECT/MITM.
  - Some clients may ignore system PAC or have separate proxy config.
- Verdict: chosen for immediate v1 safety path.

#### Option B: `NETransparentProxyProvider` as Primary Now
- Add Network Extension transparent proxy provider and route only included destination rules through it.
- Pros:
  - Best macOS architecture for destination-scoped interception.
  - Does not depend on HTTP proxy/PAC behavior.
  - Can let unhandled flows continue direct.
- Cons:
  - Requires Network Extension entitlement and app-extension/system approval.
  - Adds packaging complexity before current proxy core is stable.
  - Slower feedback loop for local SwiftPM development.
- Verdict: chosen as Phase 2 architecture, not immediate v1.

#### Option C: `NEAppProxyProvider` / Per-App VPN
- Use app-based rules to route only Antigravity app flows.
- Pros:
  - Most literal app-based routing.
  - Limits traffic by originating app rather than destination.
- Cons:
  - Apple docs state App Proxy configurations are created from managed app-layer payloads and per-app VPN routing rules; macOS uses app rules to associate MDM-managed apps.
  - Requires Network Extension entitlement.
  - Operationally heavy for a local consumer menu-bar app.
- Verdict: rejected for default plan; keep as enterprise/MDM follow-up only.

#### Option D: Keep Global Secure Web Proxy with More Bypass Rules
- Continue `networksetup -setsecurewebproxy` but add bypass domains and better restore.
- Pros:
  - Existing code path partially exists.
  - Simple to toggle.
- Cons:
  - Live testing showed incomplete proxy blocks whole-system internet.
  - Bypass lists are negative filters; any missed host can still break.
  - Failure blast radius remains too broad.
- Verdict: rejected as default. May remain only as a hidden dev-only diagnostic mode.

## ADR
Decision: Use PAC domain-scoped proxy routing for the next implementation milestone, then move to `NETransparentProxyProvider` after the local proxy and capture/replay layers are stable.

Drivers:
- Live evidence proved global Secure Web Proxy can block all HTTPS traffic.
- PAC can route by hostname and return `DIRECT` for everything else.
- Transparent Proxy is the safer long-term platform fit, but entitlement/packaging cost should not block local proxy correctness.

Alternatives considered:
- Global Secure Web Proxy: rejected due whole-system outage risk.
- `NEAppProxyProvider`: rejected for default path due managed/per-app VPN complexity.
- Transparent Proxy immediately: deferred because entitlement/extension work would slow feedback before proxy core is proven.

Why chosen:
- It minimizes blast radius now while keeping the architecture compatible with later transparent proxy routing.

Consequences:
- The app Settings text and PRD/test spec must stop promising safe global proxy behavior.
- Existing `SystemProxyManager` work should be repurposed for PAC auto-proxy snapshot/restore, not all-HTTPS proxy enable.
- Runtime logs must prove target host CONNECT arrival before any MITM/translation work resumes.
- Current experimental `PorterRuntimeController` must be revised because its blind tunnel path hung during curl.

Follow-ups:
- Update `.omx/plans/prd-antigravityporter.md` and `.omx/plans/test-spec-antigravityporter.md` to remove global-proxy-first acceptance wording.
- Create a separate Transparent Proxy plan once local PAC runtime passes safety gates.

## Updated Architecture

### Routing Layers
1. `RoutingConfigurationManager`
   - Owns enable/disable state.
   - Stores exact pre-enable network proxy snapshot.
   - Applies PAC auto-proxy config for active user network service(s).
   - Restores exact previous proxy/PAC settings.
   - Never enables all-HTTPS proxy in normal mode.

2. `PACManager`
   - Generates app-owned PAC file under Application Support.
   - PAC host allowlist:
     - `cloudcode-pa.googleapis.com`
     - `daily-cloudcode-pa.googleapis.com`
   - PAC hard exclusions/direct:
     - `oauth2.googleapis.com`
     - `accounts.google.com`
     - `www.googleapis.com`
     - `cheaprouter.uk`
     - localhost/loopback/private app URLs
   - Returns `DIRECT` for every other host.
   - Supplies PAC via documented Auto Proxy URL behavior or inline PAC JavaScript where the owning API supports it. Any local `file://` or loopback HTTP PAC hosting must be treated as empirical behavior, not an Apple-documented guarantee.

3. `LocalProxyRuntime`
   - `NWListener` on configured loopback port.
   - Accepts CONNECT.
   - Logs CONNECT host immediately.
   - Applies host policy.
   - Layered host behavior:
     - PAC layer: non-target hosts return `DIRECT` and should not reach local proxy.
     - Proxy layer: excluded auth/userinfo hosts that still reach local proxy are blind tunneled and never TLS-terminated.
     - Proxy layer: unexpected non-target hosts are rejected fast with a visible log in normal mode; direct tunnel for unexpected hosts is dev-only.
   - For target host:
     - Phase 1: capture/log CONNECT and optionally blind tunnel to avoid blocking.
     - Phase 2: MITM TLS only after pass-through safety is proven.

4. `ProxyHealthGuard`
   - Before enabling PAC, prove listener is bound and health endpoint responds.
   - If listener dies, disable PAC or update UI with one-click recovery.
   - All network operations have deadlines.
   - App quit must restore network config before exit.

5. Future `TransparentProxyExtension`
   - Uses `NETransparentProxyProvider`.
   - Uses included rules for Google inference destinations and excluded rules for auth/cheaprouter.
   - Does not rely on DNS or proxy settings inside `NETransparentProxyNetworkSettings`; Apple documents that `NETransparentProxyProvider` ignores `NEDNSSettings` and `NEProxySettings` there.
   - Reuses `HostPolicy`, classifier, translators, and logging.

### Existing Modules To Keep
- `CertificateAuthority`: keep, but do not force trust install before routing visibility.
- `SettingsStore`: keep model add/edit/delete/toggle work.
- `RequestLog`: keep sanitized UI ring buffer; extend with route/runtime events.
- `CheapRouterClient`: keep proxy-bypassing URLSession configuration.
- `ProxyCore`: keep parsers/classifier/planner; add timeout-oriented runtime tests.

### Existing Modules To Replace/Refactor
- `SystemProxyManager`
  - Split into:
    - `NetworkServiceSnapshotReader`
    - `SecureWebProxyManager` (dev-only/legacy, not default)
    - `AutoProxyPACManager` (new default)
- `PorterRuntimeController`
  - Rework or replace. Current experimental blind tunnel timed out under curl and must not be the production runtime.

## Implementation Phases

### Phase 0: Safety Lockout
Goal: prevent repeat system-wide outage.

Tasks:
- Disable/hide current global Secure Web Proxy enable path in UI.
- On app launch, detect if any active service points HTTPS proxy to `127.0.0.1:8877`; show recovery banner and restore/disable if app-owned marker exists.
- Add visible warning if user tries to enable proxy while runtime health check fails.
- Add dev-only global proxy flag behind explicit compile/runtime guard if needed for low-level tests.

Acceptance:
- Fresh app build cannot enable global all-HTTPS proxy from normal UI.
- If app is killed while routing active, relaunch can restore prior network settings.
- `networksetup -getsecurewebproxy Wi-Fi` stays unchanged when normal enable uses PAC.

### Phase 1: PAC Domain Routing Model
Goal: build and test target-only PAC behavior without mutating live system routing yet.

Tasks:
- Add `PACManager` with deterministic PAC script generator and tests.
- Add network service snapshot/restore for Auto Proxy URL and existing proxy settings.
- Add mocked/dry-run apply and restore plans for Wi-Fi and any active service selected by the app.
- PAC returns `PROXY 127.0.0.1:8877` only for target Google inference hosts; `DIRECT` otherwise.
- Add UI status rows:
  - Routing mode: `PAC domain scoped`
  - Active services
  - PAC URL/path
  - Recovery command(s)
- Add "Disable routing / Restore network" button independent of proxy listener state.

Acceptance:
- `example.com`, `openai.com`, `cheaprouter.uk`, `accounts.google.com`, `oauth2.googleapis.com`, `www.googleapis.com` resolve `DIRECT` in PAC unit tests.
- Target Google inference hosts resolve to local proxy in PAC unit tests.
- Mock apply/restore tests preserve previous Auto Proxy and Secure Web Proxy settings exactly.
- No live PAC/system proxy mutation occurs in this phase.

### Phase 2: Non-Hanging Local CONNECT Runtime
Goal: target CONNECTs log and do not hang clients.

Tasks:
- Replace/repair `PorterRuntimeController` with explicit connection state machine.
- Add deadlines:
  - CONNECT header read: 5s
  - upstream TCP connect: 8s
  - idle tunnel: configurable, default 120s
  - write completion: 10s
- For Phase 2, blind tunnel target hosts after logging unless capture/MITM mode is explicitly enabled.
- Add loopback health endpoint or internal runtime probe.
- Add integration test with a local fake upstream server proving CONNECT tunnel completes.
- Add integration test for upstream dial failure returning `502` within timeout.
- Unexpected hosts routed into the local proxy reject fast with a visible log by default; direct tunneling unexpected hosts is dev-only.
- Add log event on every accepted CONNECT:
  - timestamp
  - host:port
  - routing mode
  - action: `blind tunnel`, `mitm pending`, `rejected`, or `failed`
  - latency/status

Acceptance:
- `curl --proxy http://127.0.0.1:8877 https://example.com --max-time 10` either completes or returns controlled error within 10s; never stalls indefinitely.
- Fake upstream integration test proves bytes relay both directions.
- No system proxy/PAC enable occurs unless listener health is ready.

### Phase 3: Live PAC Enable and Antigravity Capture Visibility
Goal: enable PAC only after Phase 2 no-hang runtime gates pass, then prove native apps reach logs safely.

Tasks:
- Gate live PAC enable on:
  - listener bound
  - health probe success
  - CONNECT fake-upstream integration tests passing
  - restore snapshot persisted
- Apply PAC to selected active services.
- Enable PAC routing.
- Start Antigravity direct-mode session.
- Confirm `cloudcode-pa.googleapis.com` and `daily-cloudcode-pa.googleapis.com` CONNECTs appear in Log tab.
- Keep traffic blind-tunneled until MITM readiness is proven.
- Add "capture dry-run" status: logs host/action without decrypting body.

Acceptance:
- Manual verification proves normal browsing works with routing enabled.
- Manual verification proves non-target internet traffic does not hit AntigravityPorter logs.
- Starting Antigravity chat with `claude-sonnet-4-6` produces at least one CONNECT log entry.
- System internet remains usable during the Antigravity test.
- Disabling routing restores the pre-enable network snapshot.

### Phase 4: MITM Reintroduction Behind Safety Gate
Goal: decrypt only target inference hosts after routing safety is proven.

Tasks:
- Add per-host TLS termination only for host policy target matches.
- Ensure excluded/auth/cheaprouter hosts cannot reach leaf certificate generation.
- Add TLS handshake timeout and fail-fast errors.
- Capture negotiated ALPN and HTTP protocol.
- If HTTP/2 is negotiated, do not parse as HTTP/1.1; add HTTP/2 support plan or dependency exception.

Acceptance:
- Excluded hosts have unit/integration tests proving no MITM.
- Target host MITM logs protocol metadata.
- Failed MITM returns controlled error and does not hang app/system traffic.

### Phase 5: Capture/Replay Contract
Goal: restore capture-first parity plan on safe routing substrate.

Tasks:
- Capture sanitized fixture packs from real Antigravity direct Google traffic.
- Store private captures outside repo; sanitized fixtures only in repo if needed.
- Add replay harness for classifier, routing decisions, translator request/response.

Acceptance:
- At least one Antigravity `claude-sonnet-4-6` fixture exists.
- Replay suite proves model/action extraction.

### Phase 6: cheaprouter Routing
Goal: route selected models only after capture/replay proof.

Tasks:
- Claude models -> `/v1/messages`.
- Other OpenAI-compatible models -> `/v1/chat/completions`.
- `/v1/responses` remains capture-driven, not guessed.
- Add response/SSE translators from fixture evidence.
- Routed unsupported requests fail closed with client-compatible error.

Acceptance:
- Selected captured model routes to cheaprouter and returns client-compatible response.
- Unknown models stay direct.
- Routed unsupported schema never silently falls back to Google.

### Phase 7: Transparent Proxy Extension Track
Goal: replace PAC with platform routing when entitlement/package path is ready.

Tasks:
- Add separate extension target for `NETransparentProxyProvider`.
- Define `NETransparentProxyNetworkSettings` included/excluded rules for inference/auth/cheaprouter hosts.
- Reuse existing local proxy core or move flow handling into extension.
- Add install/approval UX and diagnostics.
- Keep PAC mode as fallback/dev mode.

Acceptance:
- Transparent Proxy mode routes only intended destinations.
- Disabling extension restores direct system network.
- PAC and Transparent Proxy modes are mutually exclusive in UI.

## Test Plan

### Unit
- PAC script generation for target/direct hosts.
- PAC escaping and custom port handling.
- Network proxy snapshot/restore serialization.
- Host policy target/exclusion behavior.
- Timeout policy values and error mapping.
- Model edit/delete persistence already covered.

### Integration
- Local CONNECT tunnel against fake upstream TLS/TCP server.
- Upstream failure returns `502` within timeout.
- Listener health gate blocks routing enable when listener unavailable.
- PAC enable/restore against mocked `networksetup` executor.
- App-owned stale marker restore.

### E2E Manual
- With routing disabled, normal internet works.
- Enable PAC routing, normal internet still works.
- Target Google inference CONNECT produces log line.
- Stop app while routing active, verify network restores or recovery banner restores.
- Antigravity `claude-sonnet-4-6` dry-run produces logs before MITM.

### Observability
- Status tab shows routing mode, listener state, active service, PAC path/URL, last error.
- Log tab records last 50 runtime events even before MITM.
- Recovery UI shows exact commands only when automatic restore fails.

## Risks And Mitigations
1. PAC ignored by Antigravity.
   - Mitigation: Phase 3 dry-run explicitly proves log arrival. If ignored, move Transparent Proxy phase earlier.
2. Local PAC file URL or loopback PAC URL unsupported by macOS/networksetup.
   - Mitigation: prefer documented Auto Proxy URL / inline PAC support where available, empirically test chosen install path, and gate routing enable on a PAC self-test.
3. Proxy runtime hangs again.
   - Mitigation: mandatory timeout integration tests before PAC enable is allowed.
4. Transparent Proxy entitlement unavailable.
   - Mitigation: keep PAC mode as v1 and document limitation.
5. HTTP/2 negotiated after MITM.
   - Mitigation: stop parser work and add HTTP/2 plan/dependency review.

## Pre-Mortem
1. User enables routing, app crashes, PAC still points target Google hosts at dead `127.0.0.1:8877`.
   - Prevent with app-owned marker, launch recovery, and independent restore button.
2. Antigravity ignores PAC, so no logs appear again.
   - Detect in Phase 3; do not debug translators until routing substrate is proven. Escalate Transparent Proxy.
3. Target CONNECT reaches app but MITM fails due HTTP/2/cert behavior.
   - Keep Phase 2 blind-tunnel logging separate from Phase 4 MITM; capture protocol metadata and fail closed only for explicitly routed MITM mode.

## Acceptance Criteria
- Normal system internet remains usable with routing enabled.
- App no longer enables global all-HTTPS Secure Web Proxy in normal mode.
- PAC unit tests prove target-only routing.
- Local proxy listener health is required before routing can enable.
- CONNECT runtime has timeout tests; no indefinite hang path remains.
- Log tab shows target CONNECTs from Antigravity before translation work.
- Existing model management and CA install tests still pass.
- Full `swift test` passes.
- Manual `networksetup` evidence proves restore state after disable.

## Available-Agent-Types Roster
- `planner`: final sequencing and release gates.
- `architect`: routing architecture, PAC vs Network Extension boundary, module ownership.
- `critic`: plan/test adequacy review.
- `executor`: Swift/AppKit/Network.framework implementation when a dedicated Swift specialist is unavailable.
- `debugger`: runtime hang/root-cause work.
- `test-engineer`: test strategy, fake upstream design, flaky test hardening.
- `security-reviewer`: CA/MITM/excluded-host/proxy safety review.
- `verifier`: final evidence collection.
- `writer`: user recovery docs and install notes.

Conceptual implementation lanes map to available roles:
- Swift UI/PAC manager lane -> `executor`.
- CONNECT runtime lane -> `executor` or `debugger`.
- Test automation lane -> `test-engineer`.
- Manual macOS QA lane -> `verifier`.

## Follow-Up Staffing Guidance

### `$ralph` Sequential Path
Use when you want one owner to keep safety gates tight:

```text
[$ralph](/Users/z/.codex/skills/ralph/SKILL.md) execute .omx/plans/implementation-plan-antigravityporter.md through Phase 3 only; do not implement MITM translation until PAC routing and non-hanging CONNECT logs are verified.
```

Recommended lanes inside Ralph:
- `executor` high: PAC manager, app UI state, restore UX.
- `executor` or `debugger` high: local CONNECT runtime and timeouts.
- `test-engineer` high: fake upstream and PAC tests.
- `security-reviewer` medium/high: host exclusions and restore blast-radius review.
- `verifier` high: system network evidence.

### `$team` Parallel Path
Use after accepting parallel edits with clear ownership:

```text
[$team](/Users/z/.codex/skills/team/SKILL.md) 4:executor implement .omx/plans/implementation-plan-antigravityporter.md Phases 0-3 only.
```

Suggested split:
- Worker 1 (`executor`, high): `PACManager`, routing settings UI, restore button.
- Worker 2 (`executor`/`debugger`, high): replace `PorterRuntimeController` with timeout state machine.
- Worker 3 (`test-engineer`, high): PAC tests, fake upstream CONNECT integration tests, no-hang regressions.
- Worker 4 (`security-reviewer`/`verifier`, medium/high): recovery checklist, host exclusion verification, manual system-network gates.

Lead-owned sequential gate:
- No worker may perform live PAC/system routing mutation until Phase 2 evidence is attached and reviewed by the lead.
- Required evidence before live PAC enable: listener health probe, no-hang fake-upstream CONNECT test, upstream-failure timeout test, persisted restore snapshot, and `git diff --check`.

Team verification path:
1. Unit tests pass.
2. Integration CONNECT no-hang tests pass.
3. `git diff --check` clean.
4. Manual evidence:
   - no global HTTPS proxy enabled in normal mode.
   - PAC enabled only when listener healthy.
   - normal internet works.
   - target host produces log.
5. Lead verifies app disable restores network state.

## Suggested Reasoning Levels
- Routing substrate / recovery / proxy runtime: high.
- PAC generator/parser tests: medium.
- UI status/log updates: medium.
- Docs/recovery text: low/medium.
- Transparent Proxy research/prototype: high.

## External References
- Apple CFNetwork PAC URL key: https://developer.apple.com/documentation/cfnetwork/kcfnetworkproxiesproxyautoconfigurlstring
- Apple `NEProxySettings.proxyAutoConfigurationURL`: https://developer.apple.com/documentation/networkextension/neproxysettings/proxyautoconfigurationurl
- Apple `NETransparentProxyNetworkSettings.includedNetworkRules`: https://developer.apple.com/documentation/networkextension/netransparentproxynetworksettings/includednetworkrules
- Apple `NEAppProxyProviderManager`: https://developer.apple.com/documentation/networkextension/neappproxyprovidermanager
- Apple `NETunnelProvider.appRules`: https://developer.apple.com/documentation/networkextension/netunnelprovider/apprules
- Apple VPN traffic routing guide: https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic

## Changelog
- Replaced global Secure Web Proxy first architecture with PAC-first routing.
- Added Transparent Proxy as explicit later phase.
- Rejected App Proxy as default due entitlement/managed per-app VPN complexity.
- Added no-hang timeout requirements before any routing enable.
- Added safety lockout and recovery gates based on live whole-system outage.
