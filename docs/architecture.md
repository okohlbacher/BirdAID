---
layout: default
title: Architecture
---

# Architecture

This document is the contributor reference for BirdAID's internal design. It covers
the pure/Lr separation invariant, the provider interface and dependency injection
model, key modules, hazards to know about, and how to add a new provider backend.

---

## Module tiers: pure vs. Lr glue

BirdAID enforces a strict two-tier separation:

| Tier | Location | Rule |
|---|---|---|
| **Pure Lua** | `src/` (excluding `src/lr/` and `src/log.lua`) | No `import 'Lr*'` anywhere. Testable with `lua` / `luajit` outside Lightroom. |
| **Lr glue** | `src/lr/`, `src/log.lua`, and top-level entry files | May `import 'Lr*'`. Not unit-testable without Lightroom. |
| **Entry points** | `IdentifyBirds.lua`, `PluginInfoProvider.lua`, `Debug*.lua` | `import 'Lr*'` allowed. Must install the require shim first. |

The negative-purity grep gate (run in CI / CODEX review) scans only `src/` for
`import` tokens and fails if a pure module has an SDK import. This invariant is what
makes the ~1,800-assertion offline test suite possible.

The glue tier is intentionally thin: it owns only the Lightroom surface
(HTTP, base64, Keychain, preview fetch, catalog write, metadata read) and injects
everything the pure core needs via a `deps` table.

---

## The `birdaid_bootstrap` require shim

**Problem:** Lightroom Classic's built-in `require` cannot resolve subdirectory or
dotted module names. `require 'src.log'` fails with "Could not load toolkit script:
src.log", and manipulating `package.path` does not help in the LrC environment.

**Solution:** `birdaid_bootstrap.lua` installs a global `require` replacement that:
1. Intercepts names starting with `src.`.
2. Converts them to a relative path (`src.log` → `src/log.lua`).
3. Resolves the absolute path using `LrPathUtils.child(_PLUGIN.path, …)`.
4. Loads the module with `dofile` and caches it.
5. Delegates all other names to the original `require`.

Every top-level entry file (anything listed in `Info.lua`) must call:

```lua
dofile(LrPathUtils.child(_PLUGIN.path, 'birdaid_bootstrap.lua'))
```

before its first `require 'src.*'`. The bootstrap is idempotent.

Under the stock-Lua CLI test runner, `package.path` already resolves `src.*` via the
runner's path extension, so the bootstrap is never loaded in tests.

---

## Provider interface

A provider is an object with one method:

```lua
identify(image, ctx) -> (response_table) | (nil, err)
```

**`image`** is the transport shape:

```lua
{
  kind   = 'bytes' | 'file',
  data   = <non-empty string>,   -- when kind == 'bytes'
  path   = <non-empty string>,   -- when kind == 'file' (crop re-query)
  dataUrl = <string>,            -- set by http.attachImage; data: URL for OpenAI
  b64     = <string>,            -- set by http.attachImage; raw base64 for Claude/Gemini
  width  = <number>,             -- exact decoded frame width
  height = <number>,             -- exact decoded frame height
}
```

**`ctx`** is the privacy-gated metadata context from `metadata.shape(rawPrefs)`:
optionally includes `gps`, `date`, `locationHint`, and `runId`.

**`response_table`** must pass `contract.validateResponse` — the common schema
described in the [Providers Reference](providers.md).

### Dependency injection

Live providers (`openai`, `claude`, `gemini`) are pure modules that accept a `deps`
table injected by the Lr glue (`src/lr/http.lua` → `buildDeps`):

```lua
deps = {
  token        : string,          -- API key (used only to build auth headers)
  model        : string,
  rateLimit    : number,          -- seconds (surfaced; orchestrator sleeps)
  httpPost     : function,        -- the LrHttp.post wrapper
  sleep        : function,        -- LrTasks.sleep
  log          : table,           -- the src.log sink
  prefs        : table,           -- raw prefs for prompt.build promptAddition
  breaker      : table,           -- run-level circuit breaker (optional)
  authHeaders  : function,        -- (token) -> [{field=,value=}]
  pcall        : function,        -- LrTasks.pcall (yield-safe; see hazard below)
}
```

The `token` value is used **only** inside `authHeaders(token)` to build the header
array. It is never logged, concatenated into an error string, or returned.

### Resolving a provider

`src/providers/init.lua` exposes:

```lua
providers.get(name, deps) -> (provider) | (nil, err)
providers.select({ provider = name, deps = deps }) -> (provider) | (nil, err)
```

`'fake'` returns the built-in deterministic fake provider (not in the settings UI).
`'openai'`, `'claude'`, `'gemini'` lazy-require their respective modules. Unknown
names return `(nil, 'provider-not-implemented:…')`.

---

## Key pure modules

| Module | Responsibility |
|---|---|
| `src/contract.lua` | `validateResponse`, `validateImage`, `denormalizeBbox`. Validates every provider response before downstream use. |
| `src/keyword.lua` | `decide(detection, prefs)` and `render(decision)`. The locked keyword format. |
| `src/writeplan.lua` | `planReport(results, prefs)`. Builds the add-only write plan and summary from AI results. Pure; no Lr. |
| `src/metadata.lua` | `shape(raw, prefs)`. Applies privacy toggles to raw metadata to produce the AI context. |
| `src/prompt.lua` | `build(ctx, prefs, opts)`. Assembles the system + user prompt from context, user addition, and box-format option. |
| `src/net/backoff.lua` | `classify(status, body, info)`, `next(attempt, status, retryAfter)`. HTTP status → outcome, deterministic exponential backoff. |
| `src/net/breaker.lua` | Run-level circuit breaker. Opens after 5 consecutive per-photo retry exhaustions. |
| `src/settings.lua` | Provider/model catalog, prefs defaults, `normalizedPrefs`, `toBool`, `sanitizePathHint`, token classification. |
| `src/redact.lua` | `redact(s)`. Value-only and key-aware secret/PII masking. Lua patterns only (no PCRE). |
| `src/platform.lua` | `capabilities(osToken)`. Pure OS-token → crop capability mapping. |
| `src/crop/bbox_transform.lua` | Normalized bbox → pixel rect for the crop pass. |
| `src/crop/merge.lua` | Per-detection merge of preview and crop results. |

---

## Key Lr glue modules

| Module | Responsibility |
|---|---|
| `src/lr/http.lua` | Single Lr HTTP surface for all providers. `makeHttpPost`, `encodeBase64`, `dataUrl`, `attachImage`, `authHeaders`, `readToken`, `buildDeps`. |
| `src/lr/preview_fetch.lua` | `fetch(photo, maxEdge, opts)`. Async JPEG preview via `requestJpegThumbnail`. |
| `src/lr/metadata_reader.lua` | `read(photo)`, `formattedFileName(photo)`. Reads GPS, date, and formatted name from an LrPhoto. |
| `src/lr/catalog_writer.lua` | `readExistingNames(photo)`, `apply(catalog, plan, …)`. Add-only keyword write-back inside a single `withWriteAccessDo` gate. |
| `src/lr/cropper.lua` | Export full-res via `LrExportSession`, invoke `magick` crop via `LrTasks.execute`. |
| `src/log.lua` | Single LrLogger sink. Composes, redacts, and emits structured log lines. The only `src/` file that imports `Lr*`. |

---

## Critical hazard: `LrTasks.pcall` vs. standard `pcall`

Lua 5.1's `pcall` is a C function. The Lightroom SDK's cooperative task scheduler
**cannot yield across a C-call boundary** — attempting to do so produces either
"Yielding is not allowed within a C or metamethod call" or "must be called from
within an LrTask", depending on where it occurs.

Both `LrHttp.post` (during network I/O) and `catalog:withWriteAccessDo` (to acquire
write lock) — as well as `catalog:createKeyword` and `photo:addKeyword` inside an
open write gate — **yield**. Wrapping any of them in standard `pcall` will fail at
runtime.

**The fix:** use `LrTasks.pcall`, which is yield-safe. BirdAID passes this in via
`deps.pcall` (providers) and `opts.pcall` (catalog writer). Pure-Lua tests fall back
to standard `pcall` because the stubs do not yield.

The transport layer (`src/lr/http.lua`) calls `LrHttp.post` **without** a surrounding
`pcall`; the provider's attempt loop wraps it with `deps.pcall = LrTasks.pcall`.

---

## The pipeline (orchestrator)

`IdentifyBirds.lua` is the real end-to-end orchestration entry. Its lifecycle:

1. **Setup** — read and normalize prefs; resolve OS capabilities; build deps once
   (`http.buildDeps`); resolve the provider (`providers.get`); validate the crop tool
   if crop is enabled.
2. **Collect phase** (entirely outside any write gate) — for each photo:
   - Fetch JPEG preview (`previewFetch.fetch`).
   - Read metadata and shape the AI context (`metadataReader.read` + `metadata.shape`).
   - Call `provider.identify(previewImage, ctx)`.
   - Optionally: run the crop pass (export full-res → crop → re-query → merge).
   - Accumulate a results table.
   - Check the run-level breaker; break if open.
   - Sleep the rate-limit delay between photos.
3. **Plan** — `writeplan.planReport(results, prefs)` builds the add-only write plan
   and summary from the collected results. Pure; no Lr.
4. **Write** — if not dry-run, `catalogWriter.apply(…)` applies the plan inside a
   single `catalog:withWriteAccessDo` gate. One clean Undo step.
5. **Report** — show the summary dialog; log the run-finished record.

No network I/O, no provider calls, and no `require` calls happen inside the write
gate.

---

## Pure-Lua test runner

```
lua test/run.lua
luajit test/run.lua
```

Run from the repository root. Requires no Lightroom installation.

The runner:
- Extends `package.path` to resolve `src.*` modules from the plugin folder.
- Provides global `assert_eq` and `assert_true` helpers.
- Discovers `test/*_spec.lua` via `io.popen("ls test/*_spec.lua")`.
- Loads each spec with `dofile`.
- Exits non-zero on any failure or if zero specs are found (a vacuous green run is
  forbidden).

Spec files cover: keyword rendering and decision logic, contract validation, backoff
policy, breaker state machine, settings validation and sanitization, redaction, prompt
building, metadata shaping, bbox transform, crop merge, fake provider, all three live
providers against fixtures, the e2e fake pipeline, and more.

The fake provider (`src/providers/fake.lua`) and fixture files in `test/fixtures/`
let the full pipeline (preview → identify → writeplan → keyword) be exercised without
a Lightroom installation or an API key.

---

## Adding a new provider backend

1. **Pure provider module** — create `src/providers/<name>.lua`. Follow the OpenAI
   provider pattern: `new(deps)` returns `{ identify, rateLimit }`. The module must
   import no `Lr*`, use `deps.httpPost` / `deps.sleep` / `deps.log` / `deps.authHeaders`
   for all I/O, and return a `contract.validateResponse`-valid response or `(nil, err)`.

2. **Request builder** — create `src/providers/<name>_request.lua`. Pure; builds the
   JSON body from a prompt string, image, and model.

3. **Response mapper** — create `src/providers/<name>_response.lua`. Pure; maps the
   provider's response to the common contract shape.

4. **Auth headers** — add a branch in `http.authHeaders(provider, token)` in
   `src/lr/http.lua` that returns the per-provider `{field=,value=}` header array.
   The token value must materialize only here and never be logged.

5. **Provider selector** — add a branch in `providers.get(name, deps)` in
   `src/providers/init.lua`. Use a lazy `pcall(require, …)` guard so the selector
   stays trivially loadable even if the module is not yet present.

6. **Settings catalog** — add an entry to `M.PROVIDERS` in `src/settings.lua` with
   `value`, `title`, and `models`. Add the per-provider Keychain key name to
   `tokenKeyFor(provider)`.

7. **Tests** — add `test/<name>_request_spec.lua`, `test/<name>_response_spec.lua`,
   and `test/<name>_provider_spec.lua` with fixture-based assertions. Add at least
   one fixture response in `test/fixtures/`.

8. **Auth headers test** — add assertions in `test/http_authheaders_spec.lua`
   confirming the new provider's header shape.

9. **CODEX review** — run `codex exec "…review the new <name> provider against the
   provider-interface invariants, backoff contract, and token-leak rules…"` and fold
   findings back before merging.

---

## Logging conventions

- Every log line goes through `src/log.lua` (`log.info`, `log.warn`, `log.error`,
  `log.event`). Never create another `LrLogger`.
- Pass a structured `fields` table: at minimum `runId` plus the subject
  (`file`, `atIndex`, `total`). On failure, include `error = tostring(err)`.
- Errors must be speaking: say what failed, on which photo, why, and that the run
  continued.
- The logging sink applies `redact()` to every composed line before writing. Do not
  rely on this — never construct a line containing the token, GPS, or raw path in the
  first place. The sink is a backstop, not the primary control.
