# AntigravityPorter Interview Summary

## Metadata
- Profile: direct-chat continuation of blocked `deep-interview`
- Context type: greenfield
- Final ambiguity: 15%
- Threshold: 20%
- Context snapshot: `.omx/context/antigravityporter-20260503T164715Z.md`
- Transport note: OMX `omx question` failed in Codex App because no attached tmux pane existed, so the workflow was cancelled and the user explicitly requested direct chat questioning.

## Transcript

### Round 1
- Question: When protocol coverage, safety, and time conflict, what should count as v1 done?
- Answer: Daily driver.
- Interpretation: v1 must reliably support real Antigravity and Gemini CLI workflows across streaming, non-streaming, `countTokens`, errors, and fallback behavior.

### Round 2
- Question: Which expensive/flaky areas may be deferred from v1 while still calling it daily-driver usable?
- Answer: None; it must natively support Antigravity.
- Interpretation: v1 cannot defer required behavior for real native Antigravity use.

### Round 3
- Question: What concrete evidence should define "natively supports Antigravity" for v1?
- Answer: Behavior parity.
- Interpretation: Antigravity should not distinguish proxied cheaprouter use from Google-backed use across streaming cadence, errors, token counts, model behavior, tool/file/image flows, and UI behavior.

### Round 4
- Question: If cheaprouter or the selected target model cannot match Google/Antigravity behavior for a request, what should the app do?
- Answer: Fail closed.
- Interpretation: For cheaprouter-routed models, unsupported or non-parity requests must return a clear Antigravity-compatible error; no silent Google fallback.

### Round 5
- Question: What evidence source should define the v1 parity test suite?
- Answer: Captured real traffic only.
- Interpretation: v1 parity fixtures must come from real local Antigravity/Gemini CLI Google request/response captures. Guessed schemas do not count.

## Pressure Pass
The original broad "daily driver" answer was challenged with a hard failure-mode tradeoff. The resolved boundary is fail-closed for routed models instead of silently preserving UX through Google fallback.
