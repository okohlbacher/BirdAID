---
layout: default
title: BirdAID
---

# BirdAID

**BirdAID** is a macOS plug-in for Adobe Lightroom Classic (LrC) that scans your
selected photos, detects whether each image contains a bird, identifies the species
using a configurable vision-AI backend, and writes the result back into your catalog
as keywords — without ever touching your existing keywords.

![BirdAID screenshot placeholder](img/placeholder.png)

_Screenshots are TODO. The image above is a placeholder._

---

## Core value

Turn a selection of photos into correctly-keyworded birds in the Lightroom catalog.
**Accurate when possible. Honestly uncertain when not.**

When a confident species identification is not possible, BirdAID degrades gracefully
to genus or family level and marks the keyword with `?` — so you always know exactly
what the AI was and was not sure of, rather than receiving a silent wrong answer.

---

## Features

- **One-click identification** — select photos in LrC, run
  _Library > Plug-in Extras > Identify Birds in Selected Photos…_, done.
- **Flat, honest keywords** — writes `English name (Latin name)` keywords; uncertain
  identifications get a trailing `?`; genus- or family-only results are marked
  `Genus sp.?` or `Family (family)?`.
- **Add-only write-back** — never removes, renames, or replaces your existing keywords.
  Re-running on the same photos is always safe.
- **Three vision-AI providers** — OpenAI (default, `gpt-4o`), Claude (Anthropic),
  and Gemini (Google). You supply your own API key, stored only in the macOS Keychain.
- **GPS + date regional prior** — passes coordinates and capture date to the AI to
  narrow the candidate species list. ON by default; can be turned off in settings.
- **Privacy-first logging** — the logging sink redacts API keys, GPS coordinates,
  and filesystem paths automatically; nothing sensitive reaches the log file.
- **Run-level circuit breaker** — if the API sustains a quota outage across multiple
  photos, the run stops early and defers remaining photos rather than burning quota.
- **Experimental crop-for-ID pass** — on macOS with ImageMagick installed, an
  optional second pass crops to the detected bird region and re-queries the AI for a
  sharper identification. Off by default.
- **Pure-Lua test suite** — over 1,800 assertions covering keyword rendering, decision
  logic, contract validation, bbox math, prompt building, backoff, and more. Runs
  outside Lightroom with `lua test/run.lua`.

---

## Status

v1.0 — macOS only.

The core end-to-end pipeline (preview fetch → vision ID → flat keyword write-back) is
verified end-to-end with **OpenAI** (including idempotent re-runs that never clobber your
keywords). **Claude** and **Gemini** are implemented behind the same provider interface and
covered by the offline test suite; switch to them in settings. The experimental crop-for-ID
pass is present but off by default pending spike verification.

---

## Quick links

- [User Guide](user-guide.md) — install, set up your API key, run the plug-in,
  understand the keyword format, privacy controls, and troubleshooting.
- [Providers Reference](providers.md) — how OpenAI, Claude, and Gemini are
  implemented and how to choose between them.
- [Architecture](architecture.md) — contributor reference: the pure/Lr separation
  invariant, the provider interface, the require shim, the test runner, and how to add
  a new provider backend.
- [CONTRIBUTING](../CONTRIBUTING.md) — dev setup, test conventions, the CODEX
  adversarial gate, GSD workflow, and the no-secrets rule.
- [GitHub repository](https://github.com/okohlbacher/BirdAID) _(link TBD)_
