---
layout: default
title: User Guide
---

# BirdAID User Guide

This guide covers everything you need to install BirdAID, set up your API key,
run your first identification, and understand what you get back.

---

## Requirements

- **Adobe Lightroom Classic** — SDK target LrC 14.0; minimum supported LrC 6.0.
  BirdAID is pure Lua + the LrC SDK with **no external tools**, so it runs on **macOS and
  Windows** (macOS is the primary tested platform; Windows is not yet formally verified).
- **A paid API key** — live identifications call a paid vision API. BirdAID does
  not bundle any AI access; you supply your own key. The default provider is OpenAI.

> **⚠️ Privacy — your images are uploaded for identification.** To identify a photo, BirdAID
> sends a **downsampled JPEG preview** of it (and, if enabled, its GPS coordinates + capture
> date) to the third-party AI provider you choose. The original full-resolution file is never
> uploaded, but the preview is. If that isn't acceptable for a given photo, don't run BirdAID
> on it. See [Privacy and GPS](#privacy-and-gps).

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

### What is sent to the AI

- A **downsampled JPEG preview** of each processed photo (never the original full-resolution file).
- If enabled (ON by default): the photo's **GPS coordinates and capture date**, as a regional prior.
- If enabled (OFF by default): a coarse **location hint** derived from the file path.

### What is never sent or logged

- Your API key. It lives only in the macOS/Windows Keychain.
- Your raw file paths or drive names.
- Your username or home directory.
- Precise GPS coordinates are automatically redacted from log output by the logging
  sink, which applies redaction to every line before writing it.

---

## Cost

Every photo you process makes one API call (on its downsampled preview). Large
selections or frequent runs incur API charges with the provider you have chosen.

Controls to manage cost:

- **Model** — smaller/cheaper models (e.g. `gpt-4o-mini`) reduce per-call cost.
- **Burst/stack clustering** — identify one photo per near-duplicate burst and copy its
  keyword to the rest (see below), so a long burst costs one call instead of many.
- **Dry run** — enable dry run in settings to see what keywords BirdAID _would_ write
  without making any API calls or changing your catalog. Useful for testing.

---

## Speed and batch features

These are in the **Throughput & clustering** and **Detection report** sections of the
settings panel. All three are **off by default** — with the defaults, BirdAID processes
photos one at a time exactly as before.

### Parallel requests

**Number of parallel requests** (1–50, default **1**) controls how many photos are sent to
the AI at the same time. Identification is dominated by network round-trip time, so raising
this makes large selections much faster. If your provider rejects requests for arriving too
fast, BirdAID automatically backs off and retries — so just lower the number a little.
Start with 4–8. (There is no separate rate-limit setting; this single control governs speed.)

### Burst / stack clustering

**Cluster bursts** groups consecutive near-duplicate frames, identifies **one** of them
(the anchor), and **copies** its keyword to the rest — so a 20-frame burst of the same bird
costs one API call, not twenty. A frame joins a cluster when it is within
**Max gap seconds** (default 1.0) of the previous frame *or* in the same Lightroom **stack**
(if **Use stacks** is on), **and** it looks similar on a coarse thumbnail (the **Similarity
threshold**, a Hamming distance 0–64; lower = stricter). Similarity is computed entirely
on-device (no extra API calls, no ImageMagick). A scene change inside the window breaks the
cluster so it is identified on its own. Note: a coarse match cannot tell apart two *different*
species framed identically — keep the threshold strict for mixed-species bursts. If the
anchor fails, its cluster is deferred (nothing written) and retried on the next run.

### Detection report

**Open detection report** writes a small SVG showing each detected bird as a labelled blue
box over the photo and opens it in your browser after the run (hover a box for the species
and confidence). It is purely a viewer — it writes a temporary file on your disk and never
uploads anything. Off by default; requires no extra tools.

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

A `429` with "rate_limit_exceeded" means you are sending requests too fast. Lower the
**Number of parallel requests** in settings (BirdAID also backs off and retries automatically).

BirdAID has a built-in exponential backoff (up to 4 attempts per photo, max 30-second
wait) and a run-level circuit breaker that stops the run early if multiple consecutive
photos exhaust retries, rather than continuing to hammer the API.

**"Keychain locked or unavailable"**

Your macOS Keychain is locked. Unlock it (open Keychain Access, or authenticate when
prompted), then reopen the BirdAID settings panel.

**No keywords written after a successful run**

Check the dry run toggle. If "Dry run" is enabled in settings, BirdAID logs the plan
but does not write anything to the catalog.

---

## Uninstalling

1. **File > Plug-in Manager**, select BirdAID, and click **Remove**.
2. The plug-in is unloaded immediately. Your catalog keywords are unchanged.
3. To remove the stored API key(s): open **Keychain Access**, search for
   `com.okohlbacher.birdaid`, and delete the entries.
4. To remove plug-in preferences: these are stored in Lightroom's own prefs database
   under the plugin identifier. Removing the plugin in step 1 is sufficient for most
   purposes; a full LrC prefs reset would also clear them.
