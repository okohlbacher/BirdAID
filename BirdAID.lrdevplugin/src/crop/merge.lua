-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/crop/merge.lua (Phase 6 — Crop-for-ID, CROP-04 merge half)
--
-- PURE module: it pulls in no Lightroom SDK namespace at load time, so it is require-able
-- under stock lua / lua5.1 / luajit for offline unit testing (the CODEX-mandated separation
-- invariant). Run under stock lua/luajit; negative-purity grep clean. (The bare SDK-load
-- token is NEVER written here, even in comments, because the purity grep false-positives on
-- it.)
--
-- The crop pass refines INDIVIDUAL detections. merge MUST retain ALL preview detections (a
-- multi-bird preview is never collapsed) and REPLACE a detection only when the crop's
-- refinement of THAT detection has a higher CONFIDENT taxonomic rank [CODEX #12 per-detection].
--
-- "Confident rank" [CODEX #13]: a detection's rank counts toward the comparison ONLY when it
-- is confident — confidence == nil (the provider omitted the hint) counts as confident, OR
-- confidence >= threshold counts as confident; confidence < threshold is NOT confident and
-- scores 0 (least specific). This is why a low-confidence species must NOT beat a
-- high-confidence genus: confidence is a sortable hint we threshold ourselves (CLAUDE.md
-- bird-ID reality), not ground truth.
--
-- Rank precedence mirrors contract RANKS specificity: species > genus > family > order > class.
-- Tie on CONFIDENT rank breaks to the crop (SPEC FR5).
--
-- Strictly Lua 5.1 common subset: no //, no goto, no <close>; unpack is global.

local M = {}

-- Rank specificity score (mirrors contract RANKS: most specific = highest).
local RANK_SCORE = { species = 5, genus = 4, family = 3, order = 2, class = 1 }

local DEFAULT_THRESHOLD = 0.6

-- isConfident(det, threshold): a detection's rank is usable when confidence is absent (nil)
-- OR confidence >= threshold. A numeric confidence below threshold is NOT confident.
local function isConfident(det, threshold)
    if type(det) ~= 'table' then return false end
    local c = det.confidence
    if c == nil then return true end
    if type(c) ~= 'number' then return false end
    return c >= threshold
end

-- confidentRankScore(det, threshold): the rank specificity score IF the detection is
-- confident, else 0 (least specific) so a low-confidence refinement cannot win on rank alone.
local function confidentRankScore(det, threshold)
    if not isConfident(det, threshold) then return 0 end
    return RANK_SCORE[det.identified_rank] or 0
end

-- rawRankScore(det): the rank specificity score IGNORING confidence (used only as the
-- second-stage tie-breaker when NEITHER side is confident, so the more-specific surviving
-- rank is preferred instead of an arbitrary downgrade to the crop).
local function rawRankScore(det)
    if type(det) ~= 'table' then return 0 end
    return RANK_SCORE[det.identified_rank] or 0
end

-- preferCrop(preview, refined, threshold) -> bool [CODEX #5 no-downgrade].
-- Two-stage decision so a tie-break NEVER downgrades to a LESS specific rank:
--   Stage 1 (confident rank): if the confident-rank scores DIFFER, the higher one wins.
--   Stage 2 (neither side confident => both confident-rank == 0, OR they are equal): fall
--           back to RAW rank specificity. If those differ, the MORE SPECIFIC rank wins; only
--           when raw ranks are ALSO equal do we tie-break to the crop. So a crop family/0.1
--           can NEVER replace a preview species/0.1 (both confident-score 0; raw species>family).
local function preferCrop(preview, refined, threshold)
    local cs = confidentRankScore(refined, threshold)
    local ps = confidentRankScore(preview, threshold)
    if cs ~= ps then return cs > ps end
    -- Confident-rank tie (includes the "both score 0 / neither confident" case): compare RAW
    -- rank so we never downgrade. Tie-break to crop ONLY when raw ranks are EQUAL.
    return rawRankScore(refined) >= rawRankScore(preview)
end

-- merge(previewResult, cropPerDetection, threshold) -> chosen result.
--   previewResult    = a validated result { bird_present, detections={...} }.
--   cropPerDetection = a table mapping preview detection INDEX -> the crop's refined
--                      detection for that bird (or absent -> no refinement for that index).
--   threshold        = the confidence gate (default 0.6).
-- Retains ALL preview detections; replaces detection i ONLY when a refinement r exists AND
-- preferCrop(preview.detections[i], r, threshold) is true (no-downgrade two-stage rule).
function M.merge(previewResult, cropPerDetection, threshold)
    threshold = (type(threshold) == 'number') and threshold or DEFAULT_THRESHOLD

    -- Degrade safety: a missing/invalid side falls back to the other (nil-safe).
    if type(previewResult) ~= 'table' then
        if type(cropPerDetection) ~= 'table' then return previewResult end
        return cropPerDetection
    end
    if type(cropPerDetection) ~= 'table' then return previewResult end

    local previewDets = previewResult.detections
    -- No detections to refine (e.g. bird_present=false) -> return preview unchanged.
    if type(previewDets) ~= 'table' or #previewDets == 0 then return previewResult end

    local mergedDets = {}
    for i = 1, #previewDets do
        local pd = previewDets[i]
        local r = cropPerDetection[i]
        if type(r) == 'table' and preferCrop(pd, r, threshold) then
            mergedDets[i] = r          -- crop refinement wins (no-downgrade two-stage rule)
        else
            mergedDets[i] = pd         -- keep the preview detection (NEVER drop)
        end
    end

    return {
        bird_present = previewResult.bird_present,
        detections   = mergedDets,
    }
end

return M
