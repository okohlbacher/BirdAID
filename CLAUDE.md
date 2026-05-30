<!-- GSD:project-start source:PROJECT.md -->

## Project

**BirdAID**

BirdAID is a macOS plug-in for Adobe Lightroom Classic (LrC) that scans the user's
selected photos, detects whether each contains a bird, identifies the species using a
configurable vision-AI backend (default OpenAI), and writes the result back into the
catalog as keywords. It is built for photographers — especially bird/wildlife shooters —
who want their libraries auto-tagged with species names, and it degrades gracefully to
genus/family (with `?` markers) when the species can't be confidently determined.

**Core Value:** Turn a selection of photos into correctly-keyworded birds in the Lightroom catalog,
without ever clobbering the user's existing data — accurate when possible, honestly
uncertain when not.

### Constraints

- **Tech stack**: Pure Lua + Lightroom Classic SDK — no native modules, vendored deps only.
- **Platform**: macOS-only for v1 — external-process/path handling is macOS-first.
- **Architecture**: AI results collected *outside* the catalog write gate; one short
  batched `withWriteAccessDo`; no network inside a write gate (Undo/coalescing reasons).

- **Security/Privacy**: API token only in Keychain, never in prefs/logs/commits; GPS/date
  and any path hint are opt-in, disclosed, and redacted in logs; path hints sanitized.

- **Cost**: preview-first; optional crop pass; configurable model and rate limit.
- **Testability**: pure-Lua core (rendering, decision logic, schema validation, bbox math,
  prompt build, merge) unit-tested outside Lightroom against a fake provider + fixtures.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:STACK.md -->

## Technology Stack

Technology stack not yet documented. Will populate after codebase mapping or first phase.
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:

- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->


---

<!-- The section below is hand-maintained domain guidance. GSD regenerates only the marker-delimited sections above; do not move this content inside those markers. -->

# BirdAID — Domain & SDK Guide (hand-maintained)

Guidance for Claude Code (and humans) working in this repository.

## What this is

**BirdAID** is a plug-in for **Adobe Lightroom Classic (LrC)** that scans selected
photos, detects whether each image contains a bird, identifies the species using a
configurable vision-AI backend, and writes the result back into the catalog as
keywords. It runs over the user's current selection automatically and degrades
gracefully when the species is uncertain.

### Core user flow
1. User selects photos in LrC and runs **Library ▸ Plug-in Extras ▸ Identify Birds**.
2. For each photo: get a JPEG preview → send to the vision AI with any GPS/date
   context → AI returns whether a bird is present, an approximate bounding box, and
   a species identification with a confidence and the most specific confident
   taxonomic rank.
3. If a bird is present, optionally re-send a tightened full-resolution crop of the
   bird region for a better ID (internal step; crops are transient, never saved as
   deliverable files).
4. Write a flat keyword per bird and report a per-photo summary.

## Locked product decisions (v1)

These were settled during spec refinement — do not silently revisit them; raise an
ADR if a phase needs to change one.

- **AI backend:** pluggable provider abstraction. **Default = OpenAI** (GPT-4o / GPT-5
  vision, using strict JSON-schema *Structured Outputs* for a guaranteed response
  shape). Claude (Anthropic, tool-use JSON) and Gemini (native bounding boxes) are
  configurable alternatives behind the same interface.
- **Crop extraction:** internal-only — a tight full-res crop of the bird region is
  used to improve species ID, then discarded. **No saved crop files** ship in v1.
  (Cropping needs an external image tool; see Constraints. The MVP may start by
  sending the whole image and add the crop-for-ID pass in a later phase.)
- **Geo enrichment:** pass **raw GPS coordinates + capture date** into the prompt as
  a regional prior. **No eBird/iNaturalist API** dependency in v1 (avoids API keys and
  commercial-licensing concerns); a location-constrained species shortlist is a
  possible future enhancement.
- **Keyword format:** **flat** `English name (Latin name)` per bird, e.g.
  `Northern Cardinal (Cardinalis cardinalis)`. Uncertainty markers:
  - confident species → `Common (Scientific)`
  - unsure species → trailing `?` e.g. `Common (Scientific)?`
  - only genus/family known → render that rank with `?` e.g. `Cardinalis sp.?` or
    family-level fallback.
  - A user-defined prompt addition (from settings) is appended to the ID prompt and
    influences rendering.
- **Selection scope:** operate on `catalog:getTargetPhotos()` (the selection, else the
  current filmstrip). Never auto-process the whole catalog without explicit action.

## Tech stack & hard SDK constraints

The LrC SDK shapes the entire architecture. Internalize these before planning code.

- **Language:** pure **Lua** (LrC SDK ~14.0, min target 6.0). No native/C modules —
  Lua's C `require` loader is disabled. Only pure-Lua libraries can be bundled.
- **Plugin shape:** a `BirdAID.lrdevplugin/` folder (dev) → `.lrplugin` (release) with
  `Info.lua` manifest (`LrSdkVersion`, `LrToolkitIdentifier`, `LrPluginName`,
  `LrLibraryMenuItems` / `LrExportMenuItems`, `LrPluginInfoProvider`).
- **Module loading (LrC require is broken for subdirs):** LrC's built-in `require`
  CANNOT resolve dotted/subdirectory names — `require 'src.log'` fails with
  *"Could not load toolkit script: src.log"*, and `package.path` does not help. `dofile`
  works. So `BirdAID.lrdevplugin/birdaid_bootstrap.lua` installs a global `require` shim
  that resolves our own `src.*` modules via `dofile`+cache. **Every toolkit entry point**
  (any file named in `Info.lua` — menu `file=`, `LrPluginInfoProvider`, export providers,
  future menu items) MUST `dofile(LrPathUtils.child(_PLUGIN.path, 'birdaid_bootstrap.lua'))`
  **before** its first `require 'src...'`. Inner modules then use `require 'src.x'` normally.
  Pure modules keep using `require 'src.x'`; under the stock-Lua test runner that resolves
  via `package.path`, so the bootstrap is LrC-only and tests are unaffected.
- **No JSON in the SDK** → bundle a pure-Lua JSON lib (`dkjson` or Jeffrey Friedl's
  `JSON.lua`). Vendored under `src/lib/`.
- **Pixel access:**
  - Previews via `photo:requestJpegThumbnail(w, h, callback)` — **async**, returns raw
    JPEG bytes; requested size is a *minimum*, actual may be larger; hold the request
    reference until the callback fires.
  - **No in-process full-res pixel read.** Full-res requires `LrExportSession` →
    JPEG/TIFF written to a temp folder → read back → clean up.
  - **No pixel/crop API.** Any actual cropping needs an external binary
    (ImageMagick `magick` / `vips`) invoked via `LrTasks.execute` with absolute paths.
    Coordinate spaces differ between preview, export, and any Develop crop — normalize
    bounding boxes against the exact frame being cropped.
- **HTTP:** `LrHttp.get/post/postMultipart` (must run inside a task). Headers are a
  table of `{field=, value=}`. Use `postMultipart` with `filePath` for image upload to
  avoid loading + base64-encoding full frames in memory (`LrStringUtils.encodeBase64`
  blocks the main thread on big images).
- **EXIF/GPS:** `photo:getRawMetadata('gps')` → `{latitude, longitude}` or nil;
  `'gpsAltitude'`, `'dateTimeOriginal'`, etc. `getFormattedMetadata` for display.
  File-path-derived geographic hints are a fallback when GPS is absent.
- **Async/concurrency:** single-threaded cooperative tasks. `LrTasks.startAsyncTask`,
  `LrFunctionContext.postAsyncTaskWithContext`, `LrTasks.yield/sleep` (rate-limit AI
  calls), `LrTasks.pcall`. `LrProgressScope` for the progress bar over N photos.
- **Catalog writes:** inside `catalog:withWriteAccessDo("…", fn)`. Build keywords with
  `catalog:createKeyword(name, synonyms, includeOnExport, parent, returnExisting=true)`
  (idempotent) and attach via `photo:addKeyword`. Consecutive write gates coalesce into
  one Undo step — batch deliberately.
- **Settings UI:** `LrPluginInfoProvider` → `sectionsForTopOfDialog(f, props)` using
  `LrView.osFactory()` (`edit_field`, `password_field`, `popup_menu`, `checkbox`).
  Non-secret prefs (model, provider, prompt addition, image-tool path) in
  `LrPrefs.prefsForPlugin()`. **API token in the macOS Keychain via `LrPasswords`**
  (`store`/`retrieve` scoped by plugin id) — never in plaintext prefs; handle nil.
- **Logging/dev loop:** `LrLogger('BirdAID'):enable('logfile')`. Log path on LrC 14+ is
  `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/BirdAID.log` (older: `~/Documents/`);
  `log.logFilePath()` returns the version-aware path. Reload via Plug-in Manager ▸ Reload;
  manifest changes may need re-add.
- **Logging & error conventions (must stay debuggable):** route EVERY log line through the
  single `src.log` sink (`log.event(level, msg, fields)` / `log.info/warn/error`); never
  create another `LrLogger`. Lines are timestamped and redacted at the sink. Always pass a
  structured `fields` table with identifying context — at minimum a `runId` to correlate a
  run, plus the subject (e.g. `file`, `atIndex`, `total`) and, on failure, the **actual
  error string** (`error = tostring(err)`). Errors must "speak": say what failed, on which
  photo, why, and that the run continued (per-photo failures are isolated via `LrTasks.pcall`
  and never abort the run). User-facing summaries surface the first error and point to
  `log.logFilePath()` for the rest; the token/GPS/path is never put in a message (the sink
  redacts as a backstop).

## Bird-ID reality (drives UX and prompts)

- Fine-grained species ID from one photo is genuinely hard for vision LLMs (~10–17%
  species top-1 on hard real-world sets; ~53%+ at genus). **Graceful degradation to
  genus/family is the normal case, not an error path.** Clean, frame-filling shots of
  common species do much better.
- Always pass GPS + date as a regional prior; it materially improves results.
- Treat the model's self-reported confidence as a *sortable hint*, not ground truth —
  threshold it ourselves before deciding species vs. genus/family rendering.
- Force structured output: a single JSON schema /
  `bird_present`, `detections[{bbox, common_name, scientific_name, confidence,
  identified_rank, rank_name, alternatives[]}]`.

## Repository layout (intended)

```
BirdAID.lrdevplugin/      # the actual plugin loaded by Lightroom
  Info.lua                # manifest
  IdentifyBirds.lua       # menu entry point
  src/
    pipeline.lua          # per-photo orchestration
    providers/            # openai.lua, claude.lua, gemini.lua + provider interface
    metadata.lua          # GPS/date/path extraction
    keywords.lua          # rendering + catalog write-back
    settings.lua          # prefs + Keychain token + InfoProvider UI
    lib/                  # vendored dkjson / JSON.lua
  PluginInfoProvider.lua
.planning/                # GSD artifacts (PROJECT.md, ROADMAP.md, phases/)
test/                     # pure-Lua unit tests runnable outside Lightroom
CLAUDE.md
```

## Development & testing

- **No git repo yet** — initialize before the first implementation phase.
- Most logic should be **testable as plain Lua outside Lightroom** by isolating pure
  functions (keyword rendering, JSON parse/validate, bbox math, prompt building) from
  `Lr*` calls. Run with `lua` / `busted` if available; `Lr*`-dependent code is verified
  by loading the plugin in Lightroom.
- LrC-level verification = load the `.lrdevplugin` in Plug-in Manager, run on a small
  test selection, inspect `BirdAID.log` and the resulting keywords. Confirm the user's
  LrC version, OpenAI key, and any image tool before a phase that needs them.
- **Secrets:** never commit API tokens, never log them. The token lives only in the
  Keychain. Redact tokens in any debug output.

## How we work here (GSD + adversarial review)

This project is driven with **GSD** (Get Shit Done, installed globally, ≥1.42.3) and
adversarially reviewed with the **CODEX CLI** (`codex`).

- Project context → `.planning/PROJECT.md`; phased plan → `.planning/ROADMAP.md`.
- Per phase: `gsd-discuss-phase` → `gsd-plan-phase` → `gsd-execute-phase` →
  `gsd-verify-work`, with atomic commits.
- **CODEX adversarial gates:** run `codex` to red-team (a) the initial spec/decisions,
  (b) every phase PLAN before execution, and (c) every phase's code review after
  execution. Fold findings back in before proceeding. Invoke non-interactively, e.g.
  `codex exec "…review prompt…"` (see `codex --help`).
