# BirdAID

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/okohlbacher/BirdAID/actions/workflows/ci.yml/badge.svg)](https://github.com/okohlbacher/BirdAID/actions/workflows/ci.yml)
![Platform: macOS | Windows](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey.svg)

**Automatically identify and keyword the birds in your Lightroom Classic library.**

BirdAID is a plug-in for Adobe Lightroom Classic (LrC), on macOS and Windows, that scans your selected
photos, detects whether each contains a bird, identifies the species using a
configurable vision-AI backend, and writes the result back into your catalog as
keywords — without ever touching your existing data.

> **v1.1.** OpenAI is the fully verified provider; Claude and Gemini are implemented behind the
> same interface. No external tools — runs on macOS and Windows (macOS is the primary tested platform).
>
> **⚠️ Privacy:** to identify a photo, BirdAID uploads a **downsampled JPEG preview** of it (never
> the original full-resolution file) to your chosen third-party AI provider.

---

## What it does

Select photos. Run _Library > Plug-in Extras > Identify Birds in Selected Photos…_
Walk away. Come back to a catalog tagged with species names.

When the AI cannot confidently identify a species, BirdAID degrades gracefully to
genus or family level and marks the keyword with `?`. You always know exactly what
was and was not confidently identified — no silent guesses.

**Core value:** turn a selection of photos into correctly-keyworded birds in the
Lightroom catalog, without ever clobbering your existing keywords. **Accurate when
possible. Honestly uncertain when not.**

---

## Key features

- **One-click identification** — operates on your current selection via a single menu command.
- **Flat, honest keywords** — writes `English name (Latin name)` keywords. Uncertain identifications get `?`; genus or family fallbacks are always marked as such.
- **Add-only write-back** — never removes, renames, or replaces existing keywords. Re-running on the same photos is always safe (idempotent).
- **Three vision-AI providers** — OpenAI (default, `gpt-4o`), Claude (Anthropic), and Gemini (Google). Switchable in settings.
- **GPS + date regional prior** — passes coordinates and capture date to the AI to narrow the candidate species list. ON by default; disclosed and toggleable.
- **Privacy-first logging** — the log sink automatically redacts API keys, GPS coordinates, and filesystem paths before writing anything to disk.
- **Run-level circuit breaker** — stops the run early if the API sustains a quota outage across multiple photos, rather than burning cost for no benefit.
- **Parallel + clustering (optional)** — process several photos at once, and collapse near-duplicate bursts to a single identification. Both off by default; no external tools.
- **Pure-Lua test suite** — 2,700+ assertions covering all pure logic, runnable outside Lightroom with `lua test/run.lua`.

---

## Quick start

1. [Download the latest release](#install), unzip, and add `BirdAID.lrplugin` in
   **File > Plug-in Manager > Add**.
2. In the plug-in settings, choose your provider (OpenAI is the default), pick a
   model, and save your API key. The key is stored only in the OS keychain (Keychain on macOS, Credential Manager on Windows) via Lightroom's secure password store.
3. Select photos in the Library module.
4. Run **Library > Plug-in Extras > Identify Birds in Selected Photos…**
5. Review the keywords written to your catalog.

---

## Install

### From a GitHub Release

1. Download `BirdAID-YYYYMMDD.zip` from the [Releases](../../releases) page and unzip it.
2. Open Lightroom Classic → **File > Plug-in Manager**.
3. Click **Add**, navigate to the unzipped `BirdAID.lrplugin` folder, select the
   folder (not a file inside it), and click **Add Plug-in**.

**After updating:** plain Reload does not pick up manifest changes. Remove the old
entry and Add the new folder. Your API key and settings are preserved.

### From source (development)

Clone this repository and add `BirdAID.lrdevplugin` (the dev folder) via
**File > Plug-in Manager > Add**. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
development setup.

---

## How it works

```
Select photos in LrC
        |
        v
  Preview fetch        requestJpegThumbnail per photo (async, JPEG bytes)
        |
        v
  Metadata read        GPS + capture date (opt-in, ON by default)
        |
        v
  Vision AI call       POST to provider API with image + GPS/date context
        |
        v
  Response validate    contract.validateResponse (every response, every provider)
        |
        v
  Write plan           Pure: decide keyword per detection, diff against existing names
        |
        v
  Catalog write        Single catalog:withWriteAccessDo gate — one clean Undo step
```

All AI calls and collection happen entirely **outside** the write gate. Network I/O
never runs inside `withWriteAccessDo`.

---

## Privacy

**API key:** stored only in the OS keychain (Keychain on macOS, Credential Manager on Windows), scoped to the BirdAID plug-in
identifier. Never written to any file, preference store, or log.

**GPS and date:** sent to the AI provider by default as a regional prior. Disclosed
in the settings panel; can be turned off in **Plug-in Manager > BirdAID settings**.

**File paths and usernames:** never sent to the AI or written to logs. The optional
path-hint feature (off by default) sends only a strict-allowlisted country name
derived from your path — never the raw path, username, or drive name.

**Log redaction:** the logging sink (`src/log.lua`) applies `src/redact.lua` to
every line before writing, masking API tokens, GPS coordinates, macOS paths under
`/Users` and `/Volumes`, and Windows drive/UNC paths.

---

## Honest expectations

Fine-grained species ID from a single photograph is genuinely hard. Real-world
species top-1 accuracy for vision AI on varied photo sets is roughly 10–17%;
genus-level accuracy is higher (~53%+). Clean, frame-filling shots of common species
in your region do noticeably better.

**Graceful degradation to genus or family is the normal outcome, not an error.**
BirdAID is designed to make that explicit with `?` markers. Passing GPS + date
materially improves accuracy.

---

## Documentation

Full documentation is in [`docs/`](docs/) and on GitHub Pages:

- [User Guide](docs/user-guide.md) — install, API key setup, running the plug-in,
  keyword format, privacy, cost, troubleshooting, and uninstall.
- [Providers Reference](docs/providers.md) — OpenAI, Claude, Gemini: auth, request
  encoding, retry policy, and the common response contract.
- [Architecture](docs/architecture.md) — contributor reference: the pure/Lr
  separation invariant, provider interface, require shim, test runner, yield-safe
  pcall hazard, and how to add a new provider.

---

## Development

```bash
lua test/run.lua        # run the pure-Lua test suite (no Lightroom needed)
luajit test/run.lua     # same with LuaJIT
```

**Code organization:** BirdAID enforces a two-tier module separation. Pure Lua modules
(`src/`, excluding `src/lr/` and `src/log.lua`) import no Lightroom SDK — they are
CLI-testable and covered by the offline suite. Lr glue (`src/lr/`, `src/log.lua`, and
entry files) owns the LrC surface and injects everything the pure core needs via
dependency injection.

**CODEX adversarial gate:** every phase plan and every phase's code output is red-teamed
with the CODEX CLI before proceeding. Findings are folded back in before each commit.

**GSD workflow:** features are driven through `/gsd:discuss-phase` → `/gsd:plan-phase`
→ `/gsd:execute-phase` → `/gsd:verify-work`. See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

BirdAID is released under the MIT License — see [LICENSE](LICENSE).
Third-party components are credited in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
