---
layout: default
title: BirdAID and cloud Lightroom
---

# BirdAID and cloud Lightroom

> **Short answer:** BirdAID is a plug-in for **Lightroom Classic** only. It cannot be ported to
> the cloud‑based **Lightroom** ("Lightroom desktop / CC") as a plug‑in, and the cloud platform's
> public API cannot deliver BirdAID's core value (writing species keywords to your catalog).
> This page summarizes the research behind that conclusion. _Last reviewed: 2026‑05‑30._

People often ask whether BirdAID can also run in the newer cloud Lightroom. We investigated it
twice. The conclusion is a confident **no** for the foreseeable future — here is why, with the
specific signal that would make us revisit it.

## 1. There is no plug-in SDK for cloud Lightroom

Adobe runs two separate developer tracks:

- **Lightroom Classic** — a full Lua plug‑in SDK (`LrPlugin`, menu items, in‑process catalog and
  keyword read/write). This is what BirdAID is built on.
  ([developer.adobe.com/lightroom-classic](https://developer.adobe.com/lightroom-classic/))
- **Cloud Lightroom** — a **REST API only**, with no in‑app plug‑in or scripting model.
  ([developer.adobe.com/lightroom](https://developer.adobe.com/lightroom/))

Adobe's next‑generation plug‑in framework, **UXP** (used by Photoshop, InDesign, Illustrator,
Premiere, After Effects, Bridge, …), **does not include either Lightroom**. A long‑running Adobe
community request for third‑party plug‑in support in cloud Lightroom (open since 2017) remains
unimplemented; the 2024 "roundtrip editing" feature is explicitly *not* a plug‑in system. As of
the 2026 reviews, the Lightroom Classic Lua SDK is still the only plug‑in surface (it received a
routine bug‑fix in LrC 15.2, Feb 2026 — i.e. it is alive and supported).

## 2. The one integration path — the Partner REST API — cannot write keywords

The only programmatic way into a user's **cloud** catalog is the **Lightroom Services / Partner
REST API** ([docs](https://developer.adobe.com/lightroom/lightroom-api-docs/)). It is a real,
user‑authorized (OAuth/Adobe IMS) HTTPS API — but its surface is **content upload and workflow
linking**, not metadata editing:

| The API can… | The API cannot… |
|---|---|
| List/read assets; create assets; upload master files | **Write keywords / IPTC tags** to your catalog |
| Read/write XMP **develop** settings (tone/color) | Write captions, titles, star ratings, color labels |
| Create/manage albums; add/remove assets | Edit the user‑visible keyword list at all |
| Store a 1024‑char opaque `servicePayload` per asset | Inject tags the user can see/search in the app |

The **decisive blocker:** there is **no endpoint to write keywords or user‑visible metadata** to an
existing asset. BirdAID's entire value — putting `Northern Cardinal (Cardinalis cardinalis)` onto
your photo — is exactly the operation the API does not offer. (The API changelog has not moved since
**mid‑2021**, reinforcing that this is a stable, content‑oriented surface, not a catalog editor.)

## 3. The other Adobe API (Firefly Services) is also a dead end here

The separate **Firefly Services Lightroom API** does Auto Tone / presets / XMP edits on
caller‑supplied image files via server‑to‑server OAuth. It has **no concept of a user's catalog**,
no keyword write, and requires an **enterprise contract** (credit‑based, ~\$1,000/month minimum).
Architecturally and commercially unsuitable for BirdAID.

## 4. What a "BirdAID for cloud" would actually be

Not a plug‑in. It would be a **separate product** — a web or desktop service that OAuths into the
user's cloud catalog over HTTP — and even then it **could not write keywords** with today's API.
The only reuse would be BirdAID's **pure core** (provider abstraction, JSON schema/contract,
keyword rendering, decision logic), which is already isolated and Lightroom‑free in this codebase.
That is a future sibling project, not a port — and it is blocked on Adobe, not on us.

## 5. Verdict and the trigger to revisit

**Out of scope** for BirdAID and any near‑term milestone. The market interest is real (e.g. the
open‑source **WildlifeAI**, Jan 2025, runs a local model for 400–1000 bird species) — which actually
validates BirdAID's differentiators (GPS/date priors, honest genus/family uncertainty, a pluggable
multi‑provider backend) — but none of that changes the platform gap.

**Re‑open this only if** Adobe adds a **keyword / IPTC write endpoint** to the Partner API. The
concrete watch is the public API spec:
[`AdobeDocs/lightroom-partner-apis`](https://github.com/AdobeDocs/lightroom-partner-apis) — a
semi‑annual check of its commits/changelog would surface such a change immediately. (A second,
weaker trigger: UXP gaining Lightroom as a host app.)

---

_This summary condenses the internal feasibility research (BL‑05). It reflects Adobe's documented
APIs as of 2026‑05‑30 and will go stale — verify against the linked sources before acting on it._
