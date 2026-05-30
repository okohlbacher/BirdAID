-- test/crop_merge_spec.lua (Phase 6 — Crop-for-ID, PURE per-detection merge, CROP-04)
--
-- Exercises BirdAID.lrdevplugin/src/crop/merge.lua: a PURE module (pulls in NO Lightroom SDK
-- namespace at load time), require-able under stock lua / luajit. Covers the per-detection,
-- confidence-thresholded merge rule [CODEX #12 per-detection, #13 confident rank]:
--   * retains ALL preview detections (never drops one);
--   * replaces a detection only when the crop's refinement of THAT detection has a higher
--     CONFIDENT rank (a rank counts only when confidence==nil OR confidence>=threshold);
--   * tie-breaks to the crop;
--   * a low-confidence species must NOT beat a high-confidence genus;
--   * nil/degraded either side is handled (degrade gracefully).
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no //, no goto, no <close>; unpack global).

local MG = require('src.crop.merge')

-- helper: a minimal valid-shaped detection.
local function det(rank, common, sci, conf)
    return {
        bbox = { 0.1, 0.1, 0.9, 0.9 },
        common_name = common,
        scientific_name = sci,
        identified_rank = rank,
        rank_name = common,
        confidence = conf,  -- may be nil
    }
end

-- =====================================================================
-- Multi-bird per-detection retention [CODEX #12]: crop refines detection[1] (genus->species),
-- detection[2] has NO refinement -> result has 2 detections; [1] is the crop's species, [2]
-- is the preview original (NOT dropped).
-- =====================================================================
do
    local preview = {
        bird_present = true,
        detections = {
            det('genus', 'Cardinalis sp.', 'Cardinalis', 0.7),
            det('species', 'Blue Jay', 'Cyanocitta cristata', 0.8),
        },
    }
    local cropPerDetection = {
        [1] = det('species', 'Northern Cardinal', 'Cardinalis cardinalis', 0.9),
        -- [2] absent -> no refinement
    }
    local merged = MG.merge(preview, cropPerDetection, 0.6)
    assert_eq(#merged.detections, 2, "per-detection: result retains BOTH detections")
    assert_eq(merged.detections[1].identified_rank, 'species',
        "per-detection: detection[1] upgraded to the crop's species")
    assert_eq(merged.detections[1].common_name, 'Northern Cardinal',
        "per-detection: detection[1] is the crop refinement")
    assert_eq(merged.detections[2], preview.detections[2],
        "per-detection: unrefined detection[2] kept as the preview original (not dropped)")
    assert_eq(merged.bird_present, true, "per-detection: bird_present carried from preview")
end

-- =====================================================================
-- Confidence gate [CODEX #13]: preview genus conf=0.95 vs crop species conf=0.01,
-- threshold=0.6 -> PREVIEW wins (low-conf species does NOT beat high-conf genus).
-- =====================================================================
do
    local preview = {
        bird_present = true,
        detections = { det('genus', 'Cardinalis sp.', 'Cardinalis', 0.95) },
    }
    local cropPerDetection = {
        [1] = det('species', 'Northern Cardinal', 'Cardinalis cardinalis', 0.01),
    }
    local merged = MG.merge(preview, cropPerDetection, 0.6)
    assert_eq(merged.detections[1].identified_rank, 'genus',
        "confidence gate: high-conf genus beats low-conf species")
    assert_eq(merged.detections[1], preview.detections[1],
        "confidence gate: the preview detection is retained verbatim")
end

-- inverse: crop species conf=0.9 vs preview genus conf=0.95 -> CROP wins (both confident,
-- crop's rank is more specific).
do
    local preview = {
        bird_present = true,
        detections = { det('genus', 'Cardinalis sp.', 'Cardinalis', 0.95) },
    }
    local cropPerDetection = {
        [1] = det('species', 'Northern Cardinal', 'Cardinalis cardinalis', 0.9),
    }
    local merged = MG.merge(preview, cropPerDetection, 0.6)
    assert_eq(merged.detections[1].identified_rank, 'species',
        "confidence gate inverse: both confident -> more-specific crop wins")
    assert_eq(merged.detections[1].common_name, 'Northern Cardinal',
        "confidence gate inverse: crop refinement used")
end

-- =====================================================================
-- nil confidence counts as confident [CODEX #13]: a crop species with confidence==nil beats a
-- preview genus (the provider omitted the hint; we treat the rank as usable).
-- =====================================================================
do
    local preview = {
        bird_present = true,
        detections = { det('genus', 'Cardinalis sp.', 'Cardinalis', nil) },
    }
    local cropPerDetection = {
        [1] = det('species', 'Northern Cardinal', 'Cardinalis cardinalis', nil),
    }
    local merged = MG.merge(preview, cropPerDetection, 0.6)
    assert_eq(merged.detections[1].identified_rank, 'species',
        "nil-confidence: a nil-conf species (counts as confident) beats a nil-conf genus")
end

-- =====================================================================
-- Tie-break to crop: equal CONFIDENT rank -> the crop refinement wins.
-- =====================================================================
do
    local preview = {
        bird_present = true,
        detections = { det('species', 'Preview Bird', 'Aaa bbb', 0.9) },
    }
    local cropPerDetection = {
        [1] = det('species', 'Crop Bird', 'Ccc ddd', 0.9),
    }
    local merged = MG.merge(preview, cropPerDetection, 0.6)
    assert_eq(merged.detections[1].common_name, 'Crop Bird',
        "tie-break: equal confident rank -> crop wins")
end

-- =====================================================================
-- A low-confidence crop refinement at a LESS specific rank never replaces a confident
-- preview detection (no downgrade).
-- =====================================================================
do
    local preview = {
        bird_present = true,
        detections = { det('species', 'Preview Species', 'Aaa bbb', 0.9) },
    }
    local cropPerDetection = {
        [1] = det('family', 'Some Family', 'Cardinalidae', 0.95),
    }
    local merged = MG.merge(preview, cropPerDetection, 0.6)
    assert_eq(merged.detections[1].identified_rank, 'species',
        "no-downgrade: a confident family does not replace a confident species")
    assert_eq(merged.detections[1], preview.detections[1], "no-downgrade: preview retained")
end

-- =====================================================================
-- [CODEX #5 no-downgrade] NEITHER side confident: preview species/0.1 vs crop family/0.1 at
-- threshold 0.6 -> both confident-score 0; the tie-break must NOT downgrade species to family.
-- The MORE SPECIFIC preview species is kept (a crop family must never replace a preview species).
-- =====================================================================
do
    local preview = {
        bird_present = true,
        detections = { det('species', 'Preview Species', 'Aaa bbb', 0.1) },
    }
    local cropPerDetection = {
        [1] = det('family', 'Some Family', 'Cardinalidae', 0.1),
    }
    local merged = MG.merge(preview, cropPerDetection, 0.6)
    assert_eq(merged.detections[1].identified_rank, 'species',
        "no-downgrade (both unconfident): species/0.1 not downgraded by family/0.1")
    assert_eq(merged.detections[1], preview.detections[1],
        "no-downgrade (both unconfident): preview species detection retained verbatim")
end

-- inverse direction [CODEX #5]: preview family/0.1 vs crop species/0.1, threshold 0.6 ->
-- neither confident, crop's RAW rank is more specific -> crop species is used (an UPGRADE, not
-- a downgrade, is still allowed when neither is confident).
do
    local preview = {
        bird_present = true,
        detections = { det('family', 'Preview Family', 'Cardinalidae', 0.1) },
    }
    local cropPerDetection = {
        [1] = det('species', 'Crop Species', 'Aaa bbb', 0.1),
    }
    local merged = MG.merge(preview, cropPerDetection, 0.6)
    assert_eq(merged.detections[1].identified_rank, 'species',
        "no-downgrade inverse: an unconfident more-specific crop species upgrades a family")
end

-- equal raw rank, both unconfident [CODEX #5]: species/0.1 vs species/0.1 -> tie-break to crop
-- (only when ranks are EQUAL do we prefer the crop).
do
    local preview = {
        bird_present = true,
        detections = { det('species', 'Preview Bird', 'Aaa bbb', 0.1) },
    }
    local cropPerDetection = {
        [1] = det('species', 'Crop Bird', 'Ccc ddd', 0.1),
    }
    local merged = MG.merge(preview, cropPerDetection, 0.6)
    assert_eq(merged.detections[1].common_name, 'Crop Bird',
        "no-downgrade: equal raw rank (both unconfident) -> tie-break to crop")
end

-- =====================================================================
-- Degrade safety: nil/non-table cropPerDetection -> preview unchanged.
-- =====================================================================
do
    local preview = {
        bird_present = true,
        detections = { det('genus', 'Cardinalis sp.', 'Cardinalis', 0.7) },
    }
    assert_eq(MG.merge(preview, nil, 0.6), preview,
        "degrade: nil cropPerDetection -> preview returned unchanged")
    assert_eq(MG.merge(preview, "not-a-table", 0.6), preview,
        "degrade: non-table cropPerDetection -> preview unchanged")
end

-- previewResult nil/non-table -> returns the crop result (or nil-safe equivalent).
do
    local crop = { [1] = det('species', 'X', 'Y z', 0.9) }
    assert_eq(MG.merge(nil, crop, 0.6), crop, "degrade: nil preview -> crop returned")
    assert_eq(MG.merge("x", crop, 0.6), crop, "degrade: non-table preview -> crop returned")
    -- both nil -> nil-safe (returns nil, no crash)
    assert_eq(MG.merge(nil, nil, 0.6), nil, "degrade: both nil -> nil (no crash)")
end

-- bird_present=false (no detections) -> returned unchanged.
do
    local preview = { bird_present = false, detections = {} }
    local merged = MG.merge(preview, {}, 0.6)
    assert_eq(merged.bird_present, false, "no-bird: bird_present=false carried")
    assert_eq(#merged.detections, 0, "no-bird: empty detections retained")
end

-- =====================================================================
-- threshold defaults to 0.6 when omitted; a 0.5-confidence species is NOT confident at the
-- default threshold and does not beat a confident genus.
-- =====================================================================
do
    local preview = {
        bird_present = true,
        detections = { det('genus', 'Cardinalis sp.', 'Cardinalis', 0.9) },
    }
    local cropPerDetection = { [1] = det('species', 'NC', 'Cardinalis cardinalis', 0.5) }
    local merged = MG.merge(preview, cropPerDetection)  -- no threshold -> default 0.6
    assert_eq(merged.detections[1].identified_rank, 'genus',
        "default threshold 0.6: a 0.5-conf species is not confident -> genus retained")
end

-- =====================================================================
-- NEVER raises (pcall battery over odd shapes).
-- =====================================================================
do
    local batteries = {
        { nil, nil, 0.6 },
        { {}, {}, 0.6 },
        { { bird_present = true, detections = {} }, {}, 0.6 },
        { { bird_present = true, detections = { det('species', 'A', 'B c', nil) } }, { [1] = "junk" }, 0.6 },
        { { bird_present = true }, { [1] = det('species', 'A', 'B c', 0.9) }, 0.6 },
    }
    for i = 1, #batteries do
        local a = batteries[i]
        assert_true(pcall(function() return MG.merge(a[1], a[2], a[3]) end),
            "merge never raises (battery " .. i .. ")")
    end
end
