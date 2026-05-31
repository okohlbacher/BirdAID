# Changelog

All notable changes to BirdAID are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/).

## [1.1.0] — 2026-05-30

Cross-platform + keyword-write correctness. Builds on 1.0; no migration needed (a re-run
adds any keywords that previously failed).

### Fixed
- **Uncertain / genus / family keywords now write to the catalog.** Lightroom's `createKeyword`
  silently rejected several keyword strings, so the *normal* graceful-degradation case failed to
  keyword at all. Three distinct rejections were found (via a new failed-name diagnostic) and fixed:
  - **`?`** is rejected → the uncertainty marker is now stored as ` (uncertain)` (e.g.
    `Cardinalis sp. (uncertain)`); the `?` form remains the display/report form (ADR-001).
  - **`,`** is rejected (it's Lightroom's keyword delimiter) → commas in AI-returned names
    (e.g. multi-language common names) are sanitized out of the stored keyword.
  - **Duplicate name within one write gate** → `createKeyword` returns nil on the 2nd+ call for a
    name created earlier in the same transaction (hit by clustered bursts). The writer now caches
    the keyword object per gate, so each unique name is created once and applied to every photo.

### Changed
- **Removed the experimental crop-for-ID pass** (and its ImageMagick dependency). Identification is
  now fully cloud-native on the downsampled preview, so BirdAID runs on **macOS and Windows**
  (Windows not yet formally verified). The crop/rate-limit/image-tool settings were retired.
- **Simplified the throughput controls** to a single, plain **Number of parallel requests** (1–50).

### Added
- **"Processed X of Y" progress caption** on the parallel path (the bar now shows a running count).
- **Detection-report flood guard:** the report is suppressed (with a summary note) when more than
  20 photos have detections, instead of opening a browser tab per photo.
- **Per-provider API keys are now discoverable** in settings: the key field names the active
  provider (e.g. "API token (Claude):") with a one-line explanation that each provider keeps its
  own key. (The separate per-provider Keychain slots already existed.)
- **`peakConcurrency` diagnostic** in the run summary — the max simultaneous in-flight AI calls,
  so actual parallelism is observable.

### Notes
- Privacy unchanged: a **downsampled JPEG preview** (never the full-resolution original) is uploaded
  for identification; the API token stays in the OS keychain; GPS/date are opt-in and redacted.

## [1.0.0] — 2026-05-30

First stable release. macOS only.

### Highlights
- **End-to-end bird identification → keyword write-back**, verified live with OpenAI:
  selection → JPEG preview → vision identification → flat `English name (Latin name)`
  keyword written into the Lightroom Classic catalog.
- **Add-only and idempotent:** a second run over the same photos is a true no-op; existing
  keywords are never modified or removed (one batched `withWriteAccessDo` → one Undo step).
- **Honest uncertainty:** degrades gracefully to genus/family with a `?` marker when the
  species can't be confidently determined.
- **Pluggable providers:** OpenAI (default, fully verified). Claude and Gemini are implemented
  behind the same interface and covered by the offline test suite — selectable in settings.
- **Speed & batch (off by default):** optional **parallel requests** (Max parallel 1–50)
  with a global token bucket so the aggregate provider-call rate still honors your rate limit;
  optional **burst/stack clustering** that identifies one anchor per near-duplicate burst and
  transfers its keyword to the rest (coarse on-device thumbnail similarity, no extra API calls,
  no ImageMagick); and an optional **detection report** (an in-browser SVG of the detected
  birds as labelled boxes). With all three off, processing is the same one-at-a-time path.
- **Privacy & secrets:** the API token lives only in the macOS Keychain and is never logged;
  GPS/date are opt-in, disclosed, and redacted in logs; path hints are off by default.
- **Resilient calls:** deterministic backoff + a run-level circuit breaker; quota/billing
  `429`s are surfaced as actionable errors instead of silently degrading.
- **Tested:** a pure-Lua core (rendering, decision logic, schema/contract, bbox math, prompt
  building, backoff, worker-pool gate, token bucket, clustering, JPEG-thumbnail decode, SVG,
  merge) with 3000+ assertions passing under both `lua` and `luajit`, plus release-packaging
  gates — all run in CI. Every change was adversarially code-reviewed (CODEX) before landing.

### Notes
- The crop-for-ID pass (a tightened full-res re-query) is **experimental and off by default**;
  it requires ImageMagick and macOS and is pending in-Lightroom spike verification.
- Windows is not supported in v1; the plugin fails clearly rather than misbehaving off-macOS.

## [0.9.0] — 2026-05-30

Initial public pre-release of the same pipeline (see 1.0.0). Published to validate
installation and the end-to-end run on a fresh Lightroom Classic profile.

[1.0.0]: https://github.com/okohlbacher/BirdAID/releases/tag/v1.0
[0.9.0]: https://github.com/okohlbacher/BirdAID/releases/tag/v0.9
