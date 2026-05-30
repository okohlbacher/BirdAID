# Contributing to BirdAID

Thank you for your interest in contributing. This document covers the development
setup, code conventions, testing process, and review gates.

---

## Prerequisites

- **macOS** — required for in-LrC testing and the crop pass.
- **Lua** — `lua` (5.1), `lua5.1`, or `luajit` for running the offline test suite.
  Install via Homebrew: `brew install lua` or `brew install luajit`.
- **Adobe Lightroom Classic** — needed for in-LrC integration testing. Any version
  from LrC 6.0 upwards; LrC 14+ is the recommended target.
- **CODEX CLI** (`codex`) — for adversarial review gates. Install globally.
- **GSD** (≥1.42.3) — the project workflow tool. Install globally.

Optional for the crop pass:

- **ImageMagick v7** — `brew install imagemagick`. Needed only if you are working on
  the experimental crop-for-ID feature.

---

## Repository layout

```
BirdAID.lrdevplugin/      # the Lightroom plugin
  Info.lua                # manifest
  birdaid_bootstrap.lua   # LrC require shim (install before any src.* require)
  IdentifyBirds.lua       # real menu entry point (the shipping command)
  PluginInfoProvider.lua  # settings UI (Lr glue)
  Debug*.lua              # temporary debug entry points (strip before release)
  src/
    contract.lua          # response + image shape validator
    keyword.lua           # keyword rendering + decision logic
    metadata.lua          # privacy-gated AI context builder
    platform.lua          # OS token -> capabilities map (pure)
    prompt.lua            # AI prompt builder
    redact.lua            # secret/PII redaction (pure)
    settings.lua          # provider catalog, prefs defaults, sanitization
    writeplan.lua         # add-only write plan builder (pure)
    json.lua              # dkjson wrapper
    log.lua               # single LrLogger sink (the only src/ Lr importer)
    lr/                   # Lr glue tier
      catalog_writer.lua
      cropper.lua
      http.lua
      metadata_reader.lua
      openai_http.lua     # legacy (delegates to http.lua)
      preview_fetch.lua
    net/
      backoff.lua         # HTTP classify + exponential backoff policy
      breaker.lua         # run-level circuit breaker
    providers/
      init.lua            # provider selector
      openai.lua          # pure OpenAI provider
      claude.lua          # pure Claude provider
      gemini.lua          # pure Gemini provider
      fake.lua            # deterministic fake (test/dev only)
      openai_request.lua / openai_response.lua
      claude_request.lua / claude_response.lua
      gemini_request.lua / gemini_response.lua
      response_util.lua
    crop/
      bbox_transform.lua
      cropcmd.lua
      merge.lua
      sweep.lua
    lib/
      dkjson.lua          # vendored pure-Lua JSON library
test/                     # pure-Lua spec files + fixtures
  run.lua                 # test runner
  *_spec.lua              # spec files
  fixtures/               # JSON fixture files for provider tests
.planning/                # GSD planning artifacts
docs/                     # documentation (this site)
dist/                     # release archives
```

---

## Running the test suite

```bash
lua test/run.lua        # stock lua 5.1
luajit test/run.lua     # LuaJIT (faster)
```

Run from the **repository root**. No Lightroom installation is required.

The runner exits non-zero on any failure. A vacuous green run (zero specs found) also
exits non-zero — this is intentional to catch configuration errors.

To verify the exit-code wiring:

```bash
BIRDAID_SELFTEST=1 lua test/run.lua    # runs one deliberate failure in-process
lua test/run.lua --selftest            # same via argv
```

---

## The pure/Lr separation invariant

**Pure modules** (`src/` except `src/lr/` and `src/log.lua`) must never `import 'Lr*'`.
This is enforced by a negative-purity grep gate that runs in CODEX review.

**Lr glue modules** (`src/lr/`, `src/log.lua`, and top-level entry files) are the only
files allowed to `import 'Lr*'`.

Why this matters: the offline test suite (`lua test/run.lua`) can test pure modules
directly. Any SDK import in a pure module would break that test path and violate the
invariant.

If you add a module under `src/` (not `src/lr/`), do not add any `import` statement.
All LrC primitives must be injected via a `deps` table.

---

## Lua 5.1 common subset

All Lua code must stay within the Lua 5.1 common subset that runs on both stock Lua
5.1 and LuaJIT:

- No `goto` (Lua 5.2+).
- No integer `//` floor-division (Lua 5.3+).
- No `\u{}` Unicode escapes (Lua 5.3+).
- No `<close>` to-be-closed variables (Lua 5.4+).
- Use `unpack` (global), not `table.unpack` (5.2+).
- UTF-8 string literals as raw bytes only, never as `\u{}` escapes.

---

## Adding a new feature

Follow the GSD workflow:

1. `/gsd:discuss-phase` — discuss the design and identify locked decisions that should
   not be silently changed.
2. `/gsd:plan-phase` — write the phase plan in `.planning/phases/`.
3. **CODEX adversarial review of the plan** — run `codex exec "…review the plan for
   the new <feature> phase against the provider-interface invariants, separation rule,
   token-leak rules, and locked product decisions…"` and fold findings back.
4. `/gsd:execute-phase` — implement against the plan.
5. `/gsd:verify-work` — verify the work.
6. **CODEX code review** — run `codex exec "…code review for the <feature> phase…"`
   and fold findings back before committing.

Do not make direct repository edits outside a GSD workflow unless you are explicitly
bypassing it for a trivial fix.

---

## Adding a new provider

See the [Architecture doc](docs/architecture.md#adding-a-new-provider-backend) for
the step-by-step checklist. The short version:

1. Pure provider module (`src/providers/<name>.lua`) — `new(deps)` → `{ identify, rateLimit }`.
2. Request builder (`src/providers/<name>_request.lua`) — pure JSON body builder.
3. Response mapper (`src/providers/<name>_response.lua`) — maps to the common contract.
4. Auth headers — add a branch in `http.authHeaders` in `src/lr/http.lua`.
5. Provider selector — add a lazy branch in `providers.get` in `src/providers/init.lua`.
6. Settings catalog — add to `M.PROVIDERS` and `tokenKeyFor` in `src/settings.lua`.
7. Tests — request, response, and provider spec files with fixtures.
8. CODEX review.

---

## Commit conventions

- Keep commits focused: one logical change per commit.
- Write a clear commit message: one summary line, then (optionally) a body explaining
  why.
- Do not commit API keys, tokens, GPS coordinates, or file paths. The `src/redact.lua`
  module and the logging sink are backstops; they are not a substitute for never
  putting secrets in source.
- Strip all `Debug*.lua` temporary entry points and their `Info.lua` menu registrations
  before any release commit.

---

## No-secrets rule

- **Never** commit any API key, token, or credential under any circumstances.
- **Never** add code that writes a secret to a file, prefs, or log.
- The API token lives only in the macOS Keychain, read via `LrPasswords.retrieve`.
- The logging sink (`src/log.lua`) automatically redacts secrets, but primary
  responsibility is on the code that constructs log lines: never put the token in a
  log field in the first place.

---

## In-LrC testing

Pure logic is covered by the offline test suite. Lr-glue code must be verified by
loading `BirdAID.lrdevplugin` in Plug-in Manager:

1. **File > Plug-in Manager > Add** — navigate to `BirdAID.lrdevplugin` and add it.
2. After any change to `Info.lua`, **Remove** and re-add the plugin (plain Reload
   does not pick up manifest changes). After a change to a `src/` module, a plain
   **Reload** is enough.
3. Set your provider + API key in the plug-in settings, select a small test set, and
   run **Library > Plug-in Extras > Identify Birds in Selected Photos…**. The command
   is provider-generic — switch providers (OpenAI / Claude / Gemini) in settings to
   exercise each backend through the same path.
4. Check the log at `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/BirdAID.log`
   (structured + redacted — confirm no token / path / GPS leaks).

---

## License

By contributing, you agree your contributions are licensed under the MIT License.
See [LICENSE](LICENSE) for the full text.
