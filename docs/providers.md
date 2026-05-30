---
layout: default
title: Providers Reference
---

# Providers Reference

BirdAID supports three vision-AI providers behind a common interface. Each provider
handles its own request encoding, authentication scheme, and structured-output
approach, but they all return the same contract-validated response shape to the
rest of the pipeline.

---

## Common contract

Every provider's `identify(image, ctx)` call returns a table that passes
`contract.validateResponse`. The shape is:

```
{
  bird_present : bool,
  detections   : [
    {
      bbox             : [x_min, y_min, x_max, y_max],  -- normalized [0,1], top-left origin
      common_name      : string,
      scientific_name  : string,
      confidence       : number (0..1),
      identified_rank  : "species" | "genus" | "family" | "order" | "class",
      rank_name        : string,
      alternatives     : [ { common_name, scientific_name, confidence, identified_rank,
                              rank_name } ... ]
    }
    ...
  ]
}
```

`bbox` coordinates are normalized relative to the **exact decoded frame sent** to the
provider (the JPEG preview's actual width/height). `x` increases right, `y` increases
down; `x_min <= x_max`, `y_min <= y_max`.

When retries are exhausted or a transient error is unresolvable, the provider returns
a validated **graceful degrade**: `{ bird_present = false, detections = {} }`. The run
continues; the photo is counted as "skipped" in the summary.

A non-retryable fatal error (401 unauthorized, 400 bad request, etc.) returns
`(nil, error_string)`. The orchestrator records the per-photo error, continues to the
next photo, and surfaces the error in the summary.

---

## OpenAI

**Endpoint:** `https://api.openai.com/v1/chat/completions`

**Authentication:** `Authorization: Bearer <token>` header. The token is read from
the macOS Keychain under the key `openai_api_token` at the start of each run. It is
never logged.

**Request encoding:** JSON chat completions with a vision `image_url` content part.
The preview is base64-encoded as a `data:image/jpeg;base64,…` data URL. JSON
Structured Outputs (`response_format: { type: "json_schema", … }`) enforce the
response shape at the API level, guaranteeing a parseable JSON response.

**Response mapping:** the JSON is decoded and mapped to the common contract by
`src/providers/openai_response.lua`. If the mapping fails, the result is a validated
degrade.

**Retry policy:** retries on `408`, `429`, `500`, `502`, `503`, `504`. Exponential
backoff: base 1 s, cap 30 s, max 4 attempts. Honors `Retry-After` headers. If the
server's `Retry-After` exceeds the cap, the attempt is not retried (the photo is
skipped rather than waiting an unbounded time).

---

## Claude (Anthropic)

**Endpoint:** `https://api.anthropic.com/v1/messages`

**Authentication:** `x-api-key: <token>` header plus `anthropic-version: 2023-06-01`
and `Content-Type: application/json`. The token is read from the Keychain under
`claude_api_token`.

**Request encoding:** Anthropic Messages API with a vision `image` content block.
The preview is passed as raw base64 (no `data:` prefix) with `media_type: image/jpeg`.
The tool-use / JSON pattern is used to enforce structured output.

**Response mapping:** handled by `src/providers/claude_response.lua`. Maps the
Anthropic response to the common contract. Graceful-degrade on mapping failure.

**Retry policy:** same base policy as OpenAI. Also handles `529` (Anthropic
`overloaded_error`) as a retryable status.

---

## Gemini (Google)

**Endpoint:** `https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent`

The model name is embedded in the URL path (it is not a secret). The API key is
**never** placed in the URL query string (no `?key=…`).

**Authentication:** `x-goog-api-key: <token>` header. The token is read from the
Keychain under `gemini_api_token`.

**Request encoding:** Gemini `generateContent` multipart with an `inlineData` part
carrying raw base64 JPEG. The prompt instructs the model to emit bounding boxes in
Gemini's native `box_2d` format (`[ymin, xmin, ymax, xmax]` on a `[0, 1000]` scale).

**Response mapping:** `src/providers/gemini_response.lua` reorders the bounding-box
coordinates from Gemini's `[ymin, xmin, ymax, xmax]/1000` order to the common
`[x_min, y_min, x_max, y_max]/[0,1]` convention. This reorder is tested by the
fixture suite.

**Retry policy:** on retryable responses, checks for a `retryDelay` field in the
Gemini JSON response body and uses it as the wait duration when present (takes
precedence over any `Retry-After` header). Also handles `503` (Gemini `UNAVAILABLE`)
as a retryable status in addition to the shared set.

---

## Shared infrastructure

All three providers share:

- **`src/lr/http.lua`** — the single Lr-glue adapter that performs the actual
  `LrHttp.post` call, base64 encoding, Keychain token retrieval, and per-provider
  auth header construction. Network I/O happens only here.
- **`src/net/backoff.lua`** — the pure classify + retry/backoff policy. Deterministic
  exponential backoff (no jitter, no `math.random`).
- **`src/net/breaker.lua`** — the run-level circuit breaker. Opens after 5 consecutive
  per-photo retry exhaustions and defers remaining photos.
- **`src/prompt.lua`** — the shared prompt builder. Injects GPS, date, and any
  user-configured prompt addition. Gemini gets a different bounding-box format
  directive via `prompt.build(ctx, prefs, { boxFormat = 'gemini' })`.
- **`src/contract.lua`** — validates every provider response before it reaches
  downstream code. Defence-in-depth: even a misbehaving provider cannot corrupt the
  write plan with an unexpected shape.

---

## Provider selection

The active provider is chosen in **File > Plug-in Manager > BirdAID settings**.
`src/providers/init.lua` resolves the provider name to a provider object via lazy
`require`. Unknown names fail with a speaking error; `fake` resolves to the built-in
deterministic fake provider (for testing only — not available in the settings UI).
