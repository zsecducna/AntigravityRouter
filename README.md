# AntigravityRouter

AntigravityRouter is a macOS menu bar app that adds target-provider models to Google Antigravity and routes only those selected provider models through an OpenAI/Anthropic-compatible target provider.

The app is intentionally narrow in scope. It is not a general-purpose system-wide interception proxy. It targets the Antigravity CloudCode inference flow, translates supported provider-model generation requests, and forwards Google catalog models plus everything else without provider modification.

## What It Does

- Starts a local proxy listener, by default at `127.0.0.1:8877`.
- Relaunches `/Applications/Antigravity.app` with proxy environment variables and Electron proxy arguments.
- Installs and trusts a local CA named `AntigravityRouter Local CA` so Antigravity can accept the app-generated leaf certificates used for TLS interception.
- Injects target-provider models into Antigravity's Google model catalog when provider models are enabled.
- Routes selected provider-model generation requests to the configured target provider.
- Forwards Google catalog model requests directly to Google, even when provider models are enabled.
- Keeps Antigravity model discovery, auth, account, and unrelated Google API requests on the Google/direct path.
- Shows target-provider models in the app UI by calling the configured provider's `/v1/models` endpoint.
- Relaunches Antigravity without proxy settings when you confirm Quit.

Default target provider:

```text
https://cheaprouter.uk
```

Default provider endpoints used by routed requests:

```text
POST /v1/responses
GET  /v1/models
```

## Request Flow

```mermaid
flowchart TD
    A["Antigravity"] --> B["AntigravityRouter local proxy<br/>127.0.0.1:8877"]
    B --> C{"CONNECT or direct TLS?"}
    C --> D{"Port 443?"}
    D -->|No| E["Reject"]
    D -->|Yes| F{"Target host policy"}
    F -->|Excluded host| G["Blind tunnel"]
    F -->|Unknown HTTPS host| G
    F -->|CloudCode inference host| H["MITM TLS termination"]
    H --> I["Parse HTTP request"]
    I --> J{"Path contains supported<br/>CloudCode method?"}
    J -->|No| K["Forward to Google"]
    J -->|fetchAvailableModels| L["Forward to Google<br/>then inject provider models"]
    J -->|generateContent or streamGenerateContent| M{"Selected model from<br/>provider catalog?"}
    M -->|No| K
    M -->|Yes| N["Translate to OpenAI Responses<br/>POST target /v1/responses"]
    N --> P["Translate provider response<br/>back to Google/Antigravity shape"]
    L --> P
    P --> Q["Return response to Antigravity"]
    K --> Q
    G --> R["No request translation"]
```

## Routing Rules

AntigravityRouter first decides whether a connection can be handled at all. Then, after TLS is terminated for eligible CloudCode hosts, it decides whether the HTTP request should go to Google or to the configured provider.

### Connection-Level Routing

| Traffic | Behavior |
| --- | --- |
| `cloudcode-pa.googleapis.com:443` | Eligible for MITM. |
| `daily-cloudcode-pa.googleapis.com:443` | Eligible for MITM. |
| `127.0.0.1:443` or `localhost:443` | Eligible for MITM as a local reverse-proxy path. |
| `oauth2.googleapis.com:443` | Blind tunnel. |
| `accounts.google.com:443` | Blind tunnel. |
| `www.googleapis.com:443` | Blind tunnel. |
| `cheaprouter.uk:443` | Blind tunnel; the provider call must not loop back through the proxy. |
| Unknown HTTPS hosts on port `443` | Blind tunnel. |
| Non-`443` CONNECT targets | Rejected. |

For MITM traffic, the proxy presents a leaf certificate generated from the local AntigravityRouter CA. The app only supports intercepted HTTP over TLS with `http/1.1` ALPN. Unsupported ALPN, such as `h2`, fails closed for interceptable requests.

### HTTP-Level Routing

| HTTP request | Provider models disabled | Provider models enabled |
| --- | --- | --- |
| `POST /v1internal:generateContent...` for Google catalog model | Forward to Google. | Forward to Google. |
| `POST /v1internal:streamGenerateContent...` for Google catalog model | Forward to Google. | Forward to Google. |
| `POST /v1internal:generateContent...` for injected provider model | Forward to Google. | Translate and route to provider. |
| `POST /v1internal:streamGenerateContent...` for injected provider model | Forward to Google. | Translate and route to provider. |
| `POST /v1internal:fetchAvailableModels...` | Forward to Google. | Forward to Google, then inject provider `/v1/models` IDs into the Antigravity catalog response. |
| `:countTokens` requests | Forward to Google or fail closed if translation is attempted. | Not provider-routed. |
| Auth, account, OAuth, general Google API requests | Direct or blind tunnel. | Direct or blind tunnel. |
| Unknown hosts or unrelated HTTPS traffic | Blind tunnel. | Blind tunnel. |

Important: Antigravity's own model discovery still comes from Google. When provider models are enabled, AntigravityRouter patches the Google `fetchAvailableModels` response so provider models appear in Antigravity's picker without replacing Google's catalog shape. Existing Google catalog models keep their normal Google route.

## Translation Rules

```mermaid
flowchart LR
    A["Google/Antigravity generateContent body"] --> B["Extract recursive model field"]
    B --> C["OpenAI Responses payload"]
    C --> H["POST target /v1/responses"]
    H --> I{"Original action"}
    I -->|streamGenerateContent| J["Google-style SSE stream"]
    I -->|generateContent| K["Google-style JSON response"]
```

The translator reads the Antigravity request body, extracts the model field recursively, and converts supported Google `contents` payloads into OpenAI Responses-compatible `input`. `systemInstruction` becomes `instructions`, Google function declarations become Responses `tools`, and `generationConfig.maxOutputTokens` becomes `max_output_tokens`.

Requests are translated to an OpenAI Responses payload:

```json
{
  "model": "gpt-5.5",
  "input": [],
  "instructions": "be concise",
  "stream": true
}
```

When present, `generationConfig.temperature` and `generationConfig.maxOutputTokens` are mapped to provider fields.

Unsupported actions or unsupported payload shapes fail closed instead of sending malformed requests upstream.

## Provider Models

The Models tab fetches provider models from:

```text
GET {target-provider-base-url}/v1/models
```

The parser accepts common OpenAI-style and Anthropic-style model containers, including IDs under `data`, `models`, `openai`, `anthropic`, or `claude`.

This provider-model fetch is used by the AntigravityRouter UI and by the MITM catalog patcher. The patcher forwards Antigravity's internal `fetchAvailableModels` request to Google first, then injects provider model IDs into the returned `models` object and `agentModelSorts`.

```mermaid
sequenceDiagram
    participant UI as AntigravityRouter Models tab
    participant Provider as Target provider
    participant AG as Antigravity
    participant Google as Google CloudCode

    UI->>Provider: GET /v1/models
    Provider-->>UI: Provider model IDs
    AG->>Google: /v1internal:fetchAvailableModels
    Google-->>AG: Google Antigravity model list plus injected provider IDs
```

## Setup

On first launch, AntigravityRouter opens a guided setup wizard:

1. Welcome and routing overview.
2. Generate and install the local CA certificate.
3. Configure the target provider base URL and API key.
4. Check the API key by fetching the provider model list.
5. Finish by enabling provider models and relaunching Antigravity through AntigravityRouter.

The wizard can be reopened from Settings with `Open Setup`.

When provider models are disabled, AntigravityRouter still allows the local proxy flow, but it does not inject provider models and all model requests are forwarded to Google's CloudCode endpoint.

The Status tab reports `MITM` as `On` or `Off`. It also probes the configured provider base URL so the provider row moves from `checking` to `reachable` or `unreachable` instead of staying indefinitely unchecked.

## Security And Privacy Notes

- The provider API key is stored in the macOS Keychain.
- Current settings are persisted in user defaults.
- CA material is stored through the app's keychain-backed CA store, with migration support for legacy file-backed material.
- Raw HTTP logging is local. Redacted raw logging is enabled by default.
- Unsafe full-body logging can store prompts, responses, and sensitive headers. It is disabled on each new app launch.
- The Log tab supports truncation and a configurable tail-line limit.

Do not enable unsafe full-body logging unless you need exact request and response bytes for debugging.

## Build And Test

```bash
swift test
swift build -c release --product AntigravityRouter
swift build -c release --product AntigravityPorterMonitor
```

The package requires macOS 14 or newer and Swift 6.

## Troubleshooting

### Antigravity does not hit the target provider

- Confirm `Local proxy listener` is enabled.
- Click `Relaunch Antigravity` so Antigravity starts with the proxy environment and Electron proxy arguments.
- Confirm setup completed successfully so provider models are enabled.
- Confirm the request path is `:generateContent` or `:streamGenerateContent`.
- Confirm the provider API key is saved.
- Check the Log tab for `Google direct`, `cheaprouter`, `blind tunnel`, or `fail-closed` entries.

### Antigravity shows no provider models

Confirm provider models are enabled, the provider API key is saved, and `GET {target-provider-base-url}/v1/models` returns model IDs. The internal catalog patch only runs after Google's `fetchAvailableModels` succeeds.

### TLS or certificate errors

- Run `Install CA` again from Settings.
- Relaunch Antigravity after the CA is trusted.
- If Antigravity was already running before trust was installed, quit and relaunch it through AntigravityRouter.

### Provider request fails

- Confirm the provider base URL uses `https`.
- Confirm the API key is valid for the target provider.
- Confirm the provider supports OpenAI-compatible `POST /v1/responses`.

### Logs are too large

Use `Truncate` in the Log tab and reduce `Tail log lines` in Settings.

### Quit behavior

Clicking `Quit` asks for confirmation. Confirming relaunches Antigravity without proxy-related environment variables, stops the local proxy after the relaunch succeeds, and then exits AntigravityRouter.
