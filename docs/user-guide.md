---
layout: default
title: User Guide
---

# BirdAID User Guide

This guide covers everything you need to install BirdAID, set up your API key,
run your first identification, and understand what you get back.

---

## Requirements

- **macOS** — BirdAID v1 is macOS-only. The plug-in loads on other platforms, but
  the experimental crop-for-ID pass is disabled off-macOS, and only macOS is
  tested for the full pipeline.
- **Adobe Lightroom Classic** — SDK target LrC 14.0; minimum supported LrC 6.0.
- **A paid API key** — live identifications call a paid vision API. BirdAID does
  not bundle any AI access; you supply your own key. The default provider is OpenAI.

---

## Installation

### From a GitHub Release (recommended)

1. Download the latest `BirdAID-YYYYMMDD.zip` from the Releases page and unzip it.
2. Open Lightroom Classic and go to **File > Plug-in Manager**.
3. Click **Add** and navigate to the unzipped `BirdAID.lrplugin` folder. Select the
   folder itself (not any file inside it) and click **Add Plug-in**.
4. BirdAID should appear in the list with status **Enabled**.

### From source (development)

Clone the repository and add the `BirdAID.lrdevplugin` folder in Plug-in Manager
using the same **Add** workflow. See [CONTRIBUTING](../CONTRIBUTING.md) for the
development setup.

### After updating

A plain **Reload** in Plug-in Manager does NOT pick up manifest changes. When
upgrading to a new version, **Remove** the old entry and then **Add** the new
folder again. Your API key and settings are preserved because they are stored
under a stable identifier in the macOS Keychain and Lightroom prefs respectively.

---

## Choosing a provider and model

BirdAID supports three vision-AI providers. You choose one in the settings panel.

| Provider | Default model | Notes |
|---|---|---|
| **OpenAI** (default) | `gpt-4o` | Also: `gpt-4o-mini`, `gpt-5`. Recommended starting point. Uses JSON Structured Outputs for a guaranteed response shape. |
| **Claude** (Anthropic) | `claude-opus-4-8` | Also: `claude-sonnet-4-6`, `claude-haiku-4-5`. Uses tool-use JSON. |
| **Gemini** (Google) | `gemini-3.5-flash` | Also: `gemini-3.1-pro`, `gemini-3-flash`. Uses native bounding boxes. |

Model IDs change as providers update their offerings. If a listed model ID is
retired, you can type any custom model string directly into the model field — the
plug-in will use whatever you enter.

**Recommendation:** start with OpenAI `gpt-4o`. It has the most predictable
structured-output behavior and is the most thoroughly tested path.

### Getting an API key

- **OpenAI** — create an account at [platform.openai.com](https://platform.openai.com),
  add a payment method, and generate a key under API Keys. Your key needs access to
  the GPT-4o vision model tier.
- **Claude (Anthropic)** — create an account at [console.anthropic.com](https://console.anthropic.com)
  and generate a key. Ensure your key has access to the model you select.
- **Gemini (Google)** — obtain a key from [Google AI Studio](https://aistudio.google.com)
  or Google Cloud. Ensure the key has the Generative Language API enabled.

---

## Entering your API key

1. In Lightroom Classic, go to **File > Plug-in Manager** and select BirdAID.
2. In the BirdAID settings section, choose your **Provider**.
3. Choose a **Model** from the dropdown, or type a custom model name.
4. Paste your API key into the key entry field and click **Save Key**.

Your key is stored **only in the macOS Keychain**, scoped to the BirdAID plug-in
identifier. It is never written to any Lightroom preference file, settings file, or
log. The settings panel is the only supported entry point for the key.

Each provider has its own separate Keychain slot; switching providers does not
overwrite the other provider's stored key.

If the Keychain is locked (e.g. after a system restart), the token status indicator
shows "Keychain locked or unavailable". Unlock your Keychain and open the settings
panel again.

---

## Running an identification

1. Select the photos you want to process in the **Library** module. (BirdAID operates
   on the current selection. If nothing is explicitly selected it uses the filmstrip
   contents.)
2. Go to **Library > Plug-in Extras > Identify Birds in Selected Photos…**
3. A progress bar appears with per-photo captions. You can cancel at any time.
4. When the run finishes, a summary dialog shows:
   - How many photos were processed.
   - How many birds were found, confidently identified, uncertainly identified, errored,
     and skipped.
   - The provider and model used.
   - Whether the run was a dry run.
   - A path to the log file for full detail.

A per-photo failure (failed preview, API error, etc.) is isolated and never aborts the
run. Other photos continue normally, and the error is recorded in the log.

---

## Understanding the results

BirdAID writes flat keywords directly to your catalog. The keyword format is:

| Situation | Keyword written |
|---|---|
| Confident species | `Northern Cardinal (Cardinalis cardinalis)` |
| Uncertain species | `Northern Cardinal (Cardinalis cardinalis)?` |
| Only genus known | `Cardinalis sp.?` |
| Only family known | `Cardinalidae (family)?` |

Keywords are **added only** — BirdAID never removes, renames, or replaces your
existing keywords. If you run BirdAID again on the same photos, the same keywords
are re-applied idempotently (no duplicates, no clobber).

### Honest expectations about accuracy

Fine-grained species identification from a single photograph is genuinely hard, even
for state-of-the-art vision AI. Real-world species top-1 accuracy on varied sets is
roughly 10–17%; genus-level accuracy is higher (around 53%+). Clean, frame-filling
shots of common species in your region do noticeably better.

**Graceful degradation to genus or family is the normal outcome, not an error.**
BirdAID is designed to make that degradation explicit with `?` markers rather than
silently guessing at a species.

Passing GPS coordinates and capture date (see Privacy below) materially improves
accuracy by giving the AI a regional prior. Knowing that a photo was taken in coastal
Maine in May meaningfully narrows the candidate list.

---

## Privacy and GPS

### GPS coordinates and capture date

By default, BirdAID sends each photo's **GPS coordinates and capture date** to the
AI provider you selected. This data is used as a regional prior to improve species
identification. GPS/date sharing is **ON by default** and this is disclosed in the
settings panel.

To turn it off: **File > Plug-in Manager > BirdAID settings > uncheck "Send GPS and
capture date"**.

### Location hint (path-based)

An optional coarse location hint derived from your file path is **OFF by default**.
When enabled, BirdAID looks for an unambiguous country name in your file path (e.g.
a folder named "Japan") and sends only that sanitized label to the AI — never your
raw file path, username, drive name, or any other personal information. Only a strict
allowlist of country names can ever appear in the hint.

To enable: **File > Plug-in Manager > BirdAID settings > check "Include location
hint from file path"**.

### What is never sent or logged

- Your API key. It lives only in the macOS Keychain.
- Your raw file paths or drive names.
- Your username or home directory.
- Precise GPS coordinates are automatically redacted from log output by the logging
  sink, which applies redaction to every line before writing it.

---

## Cost

Every photo you process makes at least one API call (preview-based). If the
experimental crop-for-ID pass is enabled, each detected bird triggers a second call
on the crop. Large selections or frequent runs incur API charges with the provider
you have chosen.

Controls to manage cost:

- **Model** — smaller/cheaper models (e.g. `gpt-4o-mini`) reduce per-call cost.
- **Rate limit** — configurable inter-call delay (default 1 second) prevents fast
  exhaustion of rate quotas on large selections.
- **Dry run** — enable dry run in settings to see what keywords BirdAID _would_ write
  without making any API calls or changing your catalog. Useful for testing.

---

## Experimental crop-for-ID pass

When enabled, BirdAID exports a tight full-resolution crop of the detected bird
region and sends it to the AI as a second, sharper identification attempt. The crop
is transient and is never saved as a deliverable file.

**Status: EXPERIMENTAL and OFF by default.**

Enabling the crop pass requires:

1. **macOS** — the crop pass is macOS-only (it uses an external command-line tool
   with POSIX quoting that does not work on Windows).
2. **ImageMagick v7** — install via Homebrew: `brew install imagemagick`. The `magick`
   binary must be reachable at an absolute path (e.g. `/opt/homebrew/bin/magick`).
3. In **Plug-in Manager > BirdAID settings**:
   - Enable "Crop-for-ID (experimental)".
   - Enter the absolute path to the `magick` binary.

The crop pass is validated before each run; if the tool is missing or the path is
invalid, crop is silently disabled for that run and the preview-only result is used.

---

## Troubleshooting

### Log file location

```
~/Library/Logs/Adobe/Lightroom/LrClassicLogs/BirdAID.log
```

On older versions of Lightroom Classic (before LrC 14) the log is at:

```
~/Documents/LrClassicLogs/BirdAID.log
```

The log contains a timestamped structured record of every run: which photos were
processed, what the AI returned, any errors, and which keywords were written. It
never contains your API key, precise GPS coordinates, file paths, or usernames
(these are automatically redacted by the logging sink).

The run summary dialog shows the first error and points you to the log for full
detail.

### Common problems

**"Cannot start: …" — no key set**

BirdAID aborts cleanly if no API key is found for the selected provider. Go to
**File > Plug-in Manager > BirdAID settings**, confirm the correct provider is
selected, and save your key.

**HTTP 429 / quota errors (OpenAI)**

A `429` with "insufficient_quota" means your OpenAI account has no remaining API
credit. Add credit at [platform.openai.com/account/billing](https://platform.openai.com/account/billing).

A `429` with "rate_limit_exceeded" means you are sending requests too fast. Increase
the rate limit delay in settings.

BirdAID has a built-in exponential backoff (up to 4 attempts per photo, max 30-second
wait) and a run-level circuit breaker that stops the run early if multiple consecutive
photos exhaust retries, rather than continuing to hammer the API.

**"Keychain locked or unavailable"**

Your macOS Keychain is locked. Unlock it (open Keychain Access, or authenticate when
prompted), then reopen the BirdAID settings panel.

**No keywords written after a successful run**

Check the dry run toggle. If "Dry run" is enabled in settings, BirdAID logs the plan
but does not write anything to the catalog.

**Crop-for-ID not working**

Ensure you are on macOS, ImageMagick v7 (`magick`) is installed, and the exact
absolute path is entered in settings. Check the log for a "crop disabled" or
"crop tool unavailable" message that will explain which validation failed.

---

## Uninstalling

1. **File > Plug-in Manager**, select BirdAID, and click **Remove**.
2. The plug-in is unloaded immediately. Your catalog keywords are unchanged.
3. To remove the stored API key(s): open **Keychain Access**, search for
   `com.okohlbacher.birdaid`, and delete the entries.
4. To remove plug-in preferences: these are stored in Lightroom's own prefs database
   under the plugin identifier. Removing the plugin in step 1 is sufficient for most
   purposes; a full LrC prefs reset would also clear them.
