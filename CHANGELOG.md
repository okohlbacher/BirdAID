# Changelog

All notable changes to BirdAID are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/).

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
- **Privacy & secrets:** the API token lives only in the macOS Keychain and is never logged;
  GPS/date are opt-in, disclosed, and redacted in logs; path hints are off by default.
- **Resilient calls:** deterministic backoff + a run-level circuit breaker; quota/billing
  `429`s are surfaced as actionable errors instead of silently degrading.
- **Tested:** a pure-Lua core (rendering, decision logic, schema/contract, bbox math, prompt
  building, backoff, merge) with 2457 assertions passing under both `lua` and `luajit`,
  plus release-packaging gates — all run in CI.

### Notes
- The crop-for-ID pass (a tightened full-res re-query) is **experimental and off by default**;
  it requires ImageMagick and macOS and is pending in-Lightroom spike verification.
- Windows is not supported in v1; the plugin fails clearly rather than misbehaving off-macOS.

## [0.9.0] — 2026-05-30

Initial public pre-release of the same pipeline (see 1.0.0). Published to validate
installation and the end-to-end run on a fresh Lightroom Classic profile.

[1.0.0]: https://github.com/okohlbacher/BirdAID/releases/tag/v1.0
[0.9.0]: https://github.com/okohlbacher/BirdAID/releases/tag/v0.9
