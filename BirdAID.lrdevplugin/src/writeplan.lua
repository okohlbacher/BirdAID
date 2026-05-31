-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/writeplan.lua (Phase 4 — WR-01/WR-02/WR-04/SUM-01)
--
-- PURE module: it pulls in NO Lightroom SDK namespace at load time and requires only the
-- pure src.keyword core, so it is require-able under stock lua / lua5.1 / luajit for offline
-- unit testing (the CODEX-mandated separation invariant). It is the offline-provable HEART of
-- the write half: turn the per-photo responses COLLECTED OUTSIDE any catalog write gate into
-- a plain-data write PLAN plus the SUM-01 summary. No gate, no network, no SDK here.
--
-- INPUT (assembled by the orchestrator/entry point OUTSIDE the gate):
--   results = array of per-photo records, each:
--     { photoKey = <stable string id>,
--       photo    = <opaque handle | nil>,          -- passed through untouched into the plan
--       response = <validated response table> | nil, -- nil means the per-photo step errored
--       error    = <string> | nil,                  -- present iff response is nil
--       existingNames = { [name]=true, ... } }      -- the photo's current keyword-name set
--   prefs = an ALREADY-NORMALIZED settings table (settings.normalizedPrefs): NUMBER
--     confidenceThreshold, BOOLEAN singleKeywordPerPhoto, BOOLEAN dryRun. The CALLER normalizes;
--     this module never requires settings (kept Lr-free + decoupled).
--
-- OUTPUT:
--   build(results, prefs) -> { plan, summary } where
--     plan = { entries = { { photoKey, photo, addKeywords = { <name>, ... } }, ... } }
--       (ONLY photos with a NON-EMPTY addKeywords list appear; an empty diff => no entry =>
--        the writer skips the gate when entries is empty.)
--     summary = { perRun  = { photos, found, identified, uncertain, errors, skipped },
--                 perPhoto = { [photoKey] = { found, identified, uncertain, errors, skipped, addCount } } }
--   build NEVER writes and NEVER branches on prefs.dryRun (identical regardless).
--
--   planReport(results, prefs) -> { plan, summary, dryRun = (prefs.dryRun == true) }
--     The dry-run orchestration guarantee (WR-04): calls build and returns the plan-as-report
--     with the dryRun flag set; the caller MUST NOT call the writer when report.dryRun is true.
--     planReport itself touches no Lr (it only flags the report).
--
-- LOCKED semantics (CODEX-revised):
--   * "found"      = the photo had >=1 DETECTION (NOT the bird_present flag): bird_present=true
--                    with an empty detections array => found=0, skipped=1.
--   * "identified" = KEPT (post-dedupe) confident-species keywords (rank species, uncertain=false).
--   * "uncertain"  = KEPT (post-dedupe) keywords written with uncertainty.
--   * "errors"     = response nil (identify/validate failed for that photo).
--   * "skipped"    = no detection (bird_present false OR detections empty) OR all detections
--                    too-coarse / all blank => nothing written.
--   identified/uncertain are counted from the DEDUPED kept set (two detections rendering to the
--   SAME string count ONCE).
--   * singleKeywordPerPhoto=true: keep ONLY the single best keyword by rank precedence
--     species(3) > genus(2) > family(1), tie-break by higher decision.confidence (nil => -1).
--   * DUPLICATE photoKey: ACCUMULATE deterministically — merge+dedupe addKeywords into ONE entry
--     and SUM the per-photo counts into one perPhoto[photoKey] (never drop or overwrite).
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.
-- This module imports no SDK and is kept clean of the SDK-import token so the negative-purity
-- grep prints only the known-pure requires of the keyword core + keyword_name (NIT 21).

local keyword = require('src.keyword')
local keyword_name = require('src.keyword_name')

local M = {}

-- Rank precedence for singleKeywordPerPhoto (more specific = higher).
local RANK_SCORE = { species = 3, genus = 2, family = 1 }

-- ---------------------------------------------------------------------------
-- build(results, prefs) -> { plan = {entries=...}, summary = {perRun, perPhoto} }
-- ---------------------------------------------------------------------------
function M.build(results, prefs)
    if type(results) ~= 'table' then results = {} end

    local plan = { entries = {} }
    local perPhoto = {}                 -- [photoKey] = per-photo counts
    local entryByKey = {}               -- [photoKey] = entry table (for duplicate accumulation)
    local seenNamesByKey = {}           -- [photoKey] = { [name]=true } for cross-record dedupe
    local photos = 0

    for _, r in ipairs(results) do
        local key = r.photoKey
        photos = photos + 1

        -- Get/create the per-photo counts (accumulates across duplicate photoKeys).
        local per = perPhoto[key]
        if per == nil then
            per = { found = 0, identified = 0, uncertain = 0, errors = 0, skipped = 0, addCount = 0 }
            perPhoto[key] = per
        end

        if r.response == nil then
            -- Per-photo step errored (validation/identify failure): no entry.
            per.errors = per.errors + 1
        else
            local dets = r.response.detections
            if type(dets) ~= 'table' then dets = {} end

            if #dets == 0 then
                -- No detection (found keys off DETECTIONS, not the bird_present flag).
                per.skipped = per.skipped + 1
            else
                per.found = per.found + 1

                -- Decide + render every detection; keep only writable, non-blank renders.
                local renderedRecs = {}
                for _, det in ipairs(dets) do
                    local dec = keyword.decide(det, prefs)
                    if dec.action == 'write' then
                        -- render() emits the canonical display form (may carry a trailing '?').
                        -- Map it to a Lightroom-WRITABLE name HERE so the dedupe, the add-only
                        -- diff against existing catalog names, the dry-run plan, and the counts
                        -- all use the SAME stored form (BL-15: createKeyword rejects '?').
                        local name = keyword.render(dec)
                        if name ~= nil then
                            name = keyword_name.toWritable(name)
                            renderedRecs[#renderedRecs + 1] = {
                                name = name,
                                rank = dec.rank,
                                uncertain = dec.uncertain,
                                confidence = dec.confidence,
                            }
                        end
                    end
                end

                if #renderedRecs == 0 then
                    -- All too-coarse (skip) or all blank renders: nothing written.
                    per.skipped = per.skipped + 1
                else
                    -- singleKeywordPerPhoto: reduce to the single BEST (rank, then confidence).
                    if prefs ~= nil and prefs.singleKeywordPerPhoto == true then
                        local best = nil
                        for _, rec in ipairs(renderedRecs) do
                            if best == nil then
                                best = rec
                            else
                                local rs = RANK_SCORE[rec.rank] or 0
                                local bs = RANK_SCORE[best.rank] or 0
                                local rc = rec.confidence or -1
                                local bc = best.confidence or -1
                                if rs > bs or (rs == bs and rc > bc) then
                                    best = rec
                                end
                            end
                        end
                        renderedRecs = { best }
                    end

                    -- DEDUPE by exact name (first-seen order); count from the KEPT records.
                    local seenInRec = {}
                    local keptRecs = {}
                    for _, rec in ipairs(renderedRecs) do
                        if not seenInRec[rec.name] then
                            seenInRec[rec.name] = true
                            keptRecs[#keptRecs + 1] = rec
                        end
                    end

                    -- Tally identified / uncertain from the kept deduped set.
                    for _, rec in ipairs(keptRecs) do
                        if rec.rank == 'species' and not rec.uncertain then
                            per.identified = per.identified + 1
                        else
                            per.uncertain = per.uncertain + 1
                        end
                    end

                    -- add-only diff: keptNames MINUS this photo's existing names, accumulated
                    -- across duplicate records (dedupe by name across records too).
                    local existing = r.existingNames
                    local entry = entryByKey[key]
                    local addedNames = seenNamesByKey[key]
                    for _, rec in ipairs(keptRecs) do
                        local name = rec.name
                        local already = (type(existing) == 'table' and existing[name]) and true or false
                        if not already and not (addedNames and addedNames[name]) then
                            if entry == nil then
                                entry = { photoKey = key, photo = r.photo, addKeywords = {} }
                                entryByKey[key] = entry
                                addedNames = {}
                                seenNamesByKey[key] = addedNames
                            end
                            addedNames[name] = true
                            entry.addKeywords[#entry.addKeywords + 1] = name
                        end
                    end
                end
            end
        end
    end

    -- Emit entries (only non-empty ones exist) in deterministic first-creation order, and
    -- finalize each photo's addCount to the final entry length (0 if no entry).
    -- Re-walk results to preserve a stable, first-seen-by-photoKey entry order.
    local emitted = {}
    for _, r in ipairs(results) do
        local key = r.photoKey
        local entry = entryByKey[key]
        if entry ~= nil and not emitted[key] then
            emitted[key] = true
            if #entry.addKeywords > 0 then
                plan.entries[#plan.entries + 1] = entry
            end
        end
    end

    -- Build perRun by accumulating the (final) per-photo columns; set addCount per photo.
    local perRun = { photos = photos, found = 0, identified = 0, uncertain = 0, errors = 0, skipped = 0 }
    for key, per in pairs(perPhoto) do
        local entry = entryByKey[key]
        per.addCount = (entry ~= nil) and #entry.addKeywords or 0
        perRun.found = perRun.found + per.found
        perRun.identified = perRun.identified + per.identified
        perRun.uncertain = perRun.uncertain + per.uncertain
        perRun.errors = perRun.errors + per.errors
        perRun.skipped = perRun.skipped + per.skipped
    end

    return { plan = plan, summary = { perRun = perRun, perPhoto = perPhoto } }
end

-- ---------------------------------------------------------------------------
-- planReport(results, prefs) -> { plan, summary, dryRun }   (WR-04)
-- Dry-run orchestration guarantee: build the plan-as-report and flag dryRun so the caller
-- reports and SKIPS the writer when true. Touches no Lr; build itself is dryRun-agnostic.
-- ---------------------------------------------------------------------------
function M.planReport(results, prefs)
    local r = M.build(results, prefs)
    return {
        plan = r.plan,
        summary = r.summary,
        dryRun = (prefs ~= nil and prefs.dryRun == true),
    }
end

return M
