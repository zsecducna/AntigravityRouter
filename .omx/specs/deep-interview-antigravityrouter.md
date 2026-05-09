# Deep Interview Spec: AntigravityRouter

## Metadata
- Profile: standard-equivalent direct-chat interview
- Context type: greenfield
- Final ambiguity: 15%
- Threshold: 20%
- Context snapshot: `.omx/context/antigravityrouter-20260503T164715Z.md`
- Transcript: `.omx/interviews/antigravityrouter-20260503T170711Z.md`

## Intent
Build a native macOS app that lets Google Antigravity and Gemini CLI keep their native client behavior while selected model traffic is executed through `cheaprouter.uk` instead of Google.

## Desired Outcome
`AntigravityRouter` is a macOS 14+ Apple-Silicon-only menu-bar SwiftUI app that runs a local HTTPS MITM proxy. It intercepts selected Antigravity/Gemini inference traffic, routes user-selected models to cheaprouter endpoints, translates requests/responses with behavior parity, and passes unselected or excluded Google traffic through safely.

## In Scope
- Native Swift implementation only.
- Menu-bar app with Status, Models, Settings, and Log tabs.
- Local configurable proxy, default `127.0.0.1:8877`.
- System HTTPS proxy enable/restore.
- Local CA generation, Keychain storage, user trust workflow, and per-host leaf certs.
- Never MITM OAuth/userinfo hosts.
- Intercept Antigravity and Gemini CLI inference endpoints listed in the original brief.
- Per-model routing with unknown models defaulting to Google direct.
- cheaprouter API key stored in Keychain and sent only to cheaprouter.
- Native Antigravity behavior parity for routed models.
- Streaming, non-streaming, `countTokens`, errors, fallback policy, token counts, tool/file/image flows, and UI behavior as required by captured real traffic.

## Out of Scope / Non-goals
- Demo-only or fixture-guessed support.
- Silent fallback to Google for a model the user explicitly routed to cheaprouter.
- Treating public schema guesses as parity evidence.
- Deferring Antigravity-native required behavior from v1.

## Decision Boundaries
- If a request for a cheaprouter-routed model cannot be translated or fulfilled with parity, fail closed with a clear Antigravity-compatible error.
- Do not silently send a routed model request to Google.
- Captured real local traffic is the canonical source of truth for request/response shape and parity tests.
- Guessed schemas can guide exploration but cannot satisfy acceptance.

## Constraints
- macOS 14+.
- M-series CPU only.
- Swift only; no Python helper scripts.
- Prefer native Apple frameworks and no new dependencies unless explicitly approved later.
- NetworkExtension is not required for v1; use system proxy approach.
- OAuth and userinfo hosts must always pass through without TLS termination.

## Acceptance Criteria
- Real Antigravity workflows captured from Google-backed traffic replay successfully through AntigravityRouter for routed models.
- Real Gemini CLI workflows captured from Google-backed traffic replay successfully through AntigravityRouter for routed models.
- Antigravity cannot distinguish proxied cheaprouter execution from Google-backed execution for captured workflows.
- Streaming cadence, non-streaming responses, errors, `countTokens`, token counts, model behavior, tool/file/image flows, and UI behavior match captured behavior within explicit tolerances derived from captures.
- Unsupported routed-model requests fail closed with Antigravity-compatible errors and visible logs.
- Unselected models and excluded auth/userinfo hosts pass through without auth mutation.
- System proxy settings restore cleanly on disable and app exit/restart recovery.
- CA/private key and cheaprouter API key are stored safely in Keychain.

## Assumptions Exposed + Resolutions
- Initial assumption: v1 might be an MVP adapter. Resolution: rejected; v1 must be daily-driver usable.
- Initial assumption: some complex Antigravity behavior could be deferred. Resolution: rejected; v1 must natively support Antigravity.
- Initial assumption: fallback to Google might preserve UX. Resolution: rejected for routed models; fail closed.
- Initial assumption: schema guesses could seed implementation. Resolution: rejected for proof; real captures are canonical.

## Technical Context Findings
- Current workspace is greenfield.
- Existing artifacts are under `.omx/` only.
- No repository source tree exists yet.
- RTK guidance applies to shell commands.

## Recommended Handoff
Use `$ralplan` next for architecture/test planning before implementation because v1 requires MITM safety, certificate handling, protocol capture, and parity proof.
