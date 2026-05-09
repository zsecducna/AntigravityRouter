# AntigravityRouter Deep Interview Context

## Task statement
Build a native macOS app called `AntigravityRouter` for Apple Silicon Macs.

## Desired outcome
Menu-bar-only SwiftUI app, macOS 14+, that runs a trusted local HTTPS MITM proxy. It intercepts selected Google Antigravity and Gemini CLI inference requests and routes chosen models to `cheaprouter.uk`, while unselected models and auth-sensitive Google hosts pass through.

## Stated solution
- Local HTTP/HTTPS proxy on `127.0.0.1:8877`, configurable.
- CONNECT handling with TLS termination for target inference hosts.
- App-generated local CA stored via Keychain, with user trust flow.
- Dynamic leaf certificates for intercepted Google hostnames.
- System HTTPS proxy enable/disable via SystemConfiguration or `networksetup`.
- Request model extraction for Antigravity JSON bodies and Gemini CLI URL path models.
- Per-model route toggles in menu-bar popover UI.
- cheaprouter endpoints:
  - Claude-like models: `POST https://cheaprouter.uk/v1/messages`
  - Other models: `POST https://cheaprouter.uk/v1/chat/completions`
  - Responses endpoint listed, but no routing rule currently targets `/v1/responses`.
- Request/response translation between Google schemas and OpenAI/Anthropic-compatible cheaprouter schemas.
- Pass-through for unselected models and excluded auth/userinfo hosts.

## Probable intent hypothesis
User wants Antigravity and Gemini CLI to keep working with their native Google request formats while selectively replacing model execution with cheaper/custom provider execution through cheaprouter, without modifying either client app.

## Known facts/evidence
- Workspace `/Users/z/Desktop/antigravityRouter` is greenfield: no source files currently exist, only `.omx` state/log directories.
- No workspace-scoped `AGENTS.md` exists under `/Users/z/Desktop/antigravityRouter`; user-provided AGENTS content governs this turn.
- RTK guidance loaded from `/Users/z/.codex/RTK.md`: shell commands should be prefixed with `rtk`.
- Initial brief is detailed enough for prompt-safe use; no oversized-summary gate needed.

## Constraints
- Swift only.
- macOS 14+.
- M-series CPU only.
- Menu-bar-only app.
- No Python helper scripts.
- No new dependency approval in brief; assume conservative native-stack first.
- NetworkExtension not required; use system proxy approach.
- OAuth/userinfo hosts must never be MITM-terminated.
- Unknown/new models default to Google direct.
- cheaprouter API key stored in Keychain and only sent to cheaprouter.

## Unknowns/open questions
- Whether first release must be an actually shippable signed/notarized app or a local developer build.
- Whether target is production-grade MITM reliability from v1 or proof-of-concept with bounded model/action coverage.
- Exact Antigravity proprietary request/response schema examples are not provided.
- Exact translation fidelity expected for tool calls, multimodal content, thinking/reasoning fields, citations, safety blocks, errors, and finish reasons is not specified.
- How `/v1/responses` should be used, if at all, because the stated routing rule maps non-Claude models to `/v1/chat/completions`.
- Whether `countTokens` must be exact or approximate enough for client compatibility.
- Whether proxy configuration should affect all system HTTPS traffic or only named services, and what restore behavior must handle.

## Decision-boundary unknowns
- What OMX may decide without confirmation when safety, UX, and technical feasibility conflict.
- Whether to prioritize minimal working interception or broad protocol coverage.
- Whether fallback-to-Google is acceptable on translation failures for routed models, or failures must surface loudly.
- Whether the app may require manual certificate trust steps only, or must attempt automation where macOS allows.
- Whether app distribution/signing/notarization is in scope.

## Likely codebase touchpoints
Greenfield likely modules:
- SwiftUI menu-bar app shell and popover tabs.
- Proxy listener and CONNECT tunnel handling with Network.framework.
- TLS identity and certificate authority manager.
- Keychain storage for CA key and cheaprouter API key.
- System proxy manager.
- Model routing store and seen-model registry.
- Translators for Gemini/Antigravity to OpenAI/Anthropic-compatible requests.
- SSE translators for cheaprouter responses back to Google-compatible response streams.
- Request log ring buffer and reachability checker.

## Prompt-safe initial-context summary status
not_needed

## Direct chat interview continuation

### Round 1
- Timestamp: 2026-05-03T16:54:43Z
- Target: v1 success boundary
- Question: When protocol coverage, safety, and time conflict, what should count as v1 done?
- Answer: Daily driver.
- Interpretation: v1 must reliably support real Antigravity and Gemini CLI workflows across streaming, non-streaming, `countTokens`, error handling, and fallback behavior before it is considered complete.
- Updated ambiguity: 32%
- Remaining gates: non-goals still partial; decision boundaries unresolved; pressure pass still needed.

### Round 2
- Timestamp: 2026-05-03T16:57:54Z
- Target: non-goals / failure boundary
- Question: Which expensive/flaky areas may be deferred from v1 while still calling it daily-driver usable?
- Answer: None; it must natively support Antigravity.
- Interpretation: v1 cannot defer Responses API routing, exact-enough token counting, advanced content handling, full observed Antigravity schema behavior, or certificate trust workflow if these are required for real Antigravity native use.
- Updated ambiguity: 28%
- Remaining gates: non-goals now strict; decision boundaries still need explicit failure-mode policy; pressure pass needed.

### Round 3
- Timestamp: 2026-05-03T17:00:36Z
- Target: native Antigravity proof
- Question: What concrete evidence should define "natively supports Antigravity" for v1?
- Answer: Behavior parity.
- Interpretation: Antigravity should not be able to distinguish the proxied path from Google-backed use across streaming cadence, errors, token counts, model behavior, tool/file/image flows, and UI behavior.
- Updated ambiguity: 24%
- Remaining gates: non-goals are strict; decision boundaries must define what happens when cheaprouter/provider capability cannot match Google behavior; pressure pass active.

### Round 4
- Timestamp: 2026-05-03T17:06:00Z
- Target: hard tradeoff / pressure pass
- Question: If cheaprouter or the selected target model cannot match Google/Antigravity behavior for a request, what should the app do?
- Answer: Fail closed.
- Interpretation: For models routed to cheaprouter, the app must return a clear Antigravity-compatible error when parity cannot be met; it must never silently route that request to Google.
- Updated ambiguity: 19%
- Remaining gates: non-goals explicit; decision boundary explicit; pressure pass complete. Residual gap is the evidence source and acceptance suite for proving parity.

### Round 5
- Timestamp: 2026-05-03T17:07:11Z
- Target: parity evidence
- Question: What evidence source should define the v1 parity test suite?
- Answer: Captured real traffic only.
- Interpretation: v1 parity tests must be derived from local captures of real Antigravity/Gemini CLI Google request/response pairs. Guessed schemas, public-shape assumptions, and implementation-driven fixtures do not count as parity proof.
- Updated ambiguity: 15%
- Readiness gates: non-goals explicit; decision boundary explicit; pressure pass complete; evidence source explicit.
