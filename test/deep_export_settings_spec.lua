-- test/deep_export_settings_spec.lua (Phase 13 Plan 01 — D-01/D-01-OPENAI/D-02 export table)
--
-- Exercises BirdAID.lrdevplugin/src/deep_export.lua: a PURE module (imports NO Lr*) that turns
-- prefs + a destination path into the LR_* settings table LrExportSession consumes (the heavy
-- render glue is 13-03). Two variants per the locked per-provider policy:
--   * unconstrained full-res  (Files-API providers, D-01-ANTHROPIC/D-01-GEMINI)
--       -> LR_size_doConstrain == false
--   * { maxEdge = 2048 }      (OpenAI 2048-equiv, D-01-OPENAI; server downscales to <=2048)
--       -> LR_size_doConstrain == true, LR_size_maxWidth/Height == 2048
-- Both: JPEG, quality 0.8 (D-02), sRGB, LR_reimportExportedPhoto == false, no shared mutable state.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no //, no goto, no <close>; unpack global).

local DE = require('src.deep_export')

assert_true(type(DE.buildSettings) == 'function', "deep_export exposes buildSettings()")

local DEST = "/tmp/BirdAID/run-x/"

-- =====================================================================
-- Unconstrained full-res variant (no opts.maxEdge) — the locked LR_* table.
-- =====================================================================
do
    local s = DE.buildSettings({}, DEST)
    assert_eq(s.LR_format, 'JPEG', "full-res: LR_format == 'JPEG'")
    assert_eq(s.LR_jpeg_quality, 0.8, "full-res: LR_jpeg_quality == 0.8 (D-02)")
    assert_eq(s.LR_export_colorSpaceName, 'sRGB', "full-res: colorSpace == 'sRGB'")
    assert_eq(s.LR_size_doConstrain, false, "full-res: LR_size_doConstrain == false")
    assert_eq(s.LR_reimportExportedPhoto, false, "full-res: LR_reimportExportedPhoto == false")
    assert_eq(s.LR_export_destinationType, 'specificFolder',
        "full-res: destinationType == 'specificFolder'")
    assert_eq(s.LR_export_destinationPathPrefix, DEST,
        "full-res: destinationPathPrefix is the passed dest")
    assert_eq(s.LR_export_useSubfolder, false, "full-res: useSubfolder == false")
    assert_eq(s.LR_collisionHandling, 'rename', "full-res: collisionHandling == 'rename'")
    assert_eq(s.LR_minimizeEmbeddedMetadata, true, "full-res: minimizeEmbeddedMetadata == true")
    assert_eq(s.LR_removeLocationMetadata, true, "full-res: removeLocationMetadata == true (strips GPS)")
    -- no constrain -> the max-edge keys are absent in the unconstrained variant
    assert_eq(s.LR_size_maxWidth, nil, "full-res: no LR_size_maxWidth when unconstrained")
    assert_eq(s.LR_size_maxHeight, nil, "full-res: no LR_size_maxHeight when unconstrained")
end

-- =====================================================================
-- OpenAI 2048-equiv variant ({ maxEdge = 2048 }) — constrain ON, all else unchanged.
-- =====================================================================
do
    local s = DE.buildSettings({}, DEST, { maxEdge = 2048 })
    assert_eq(s.LR_size_doConstrain, true, "2048: LR_size_doConstrain == true")
    assert_eq(s.LR_size_maxWidth, 2048, "2048: LR_size_maxWidth == 2048")
    assert_eq(s.LR_size_maxHeight, 2048, "2048: LR_size_maxHeight == 2048")
    -- all other fields are identical to the full-res variant
    assert_eq(s.LR_format, 'JPEG', "2048: LR_format == 'JPEG'")
    assert_eq(s.LR_jpeg_quality, 0.8, "2048: LR_jpeg_quality == 0.8")
    assert_eq(s.LR_export_colorSpaceName, 'sRGB', "2048: colorSpace == 'sRGB'")
    assert_eq(s.LR_reimportExportedPhoto, false, "2048: LR_reimportExportedPhoto == false")
    assert_eq(s.LR_export_destinationPathPrefix, DEST, "2048: destinationPathPrefix is the dest")
    assert_eq(s.LR_removeLocationMetadata, true, "2048: removeLocationMetadata == true")
end

-- =====================================================================
-- A custom maxEdge value flows through unchanged (not hard-coded to 2048).
-- =====================================================================
do
    local s = DE.buildSettings({}, DEST, { maxEdge = 4096 })
    assert_eq(s.LR_size_doConstrain, true, "custom maxEdge: doConstrain == true")
    assert_eq(s.LR_size_maxWidth, 4096, "custom maxEdge: maxWidth == 4096 (flows through)")
    assert_eq(s.LR_size_maxHeight, 4096, "custom maxEdge: maxHeight == 4096 (flows through)")
end

-- =====================================================================
-- NEVER raises on nil prefs / nil opts; returns a FRESH table each call (no shared state).
-- =====================================================================
do
    assert_true(pcall(DE.buildSettings, nil, DEST), "buildSettings never raises on nil prefs")
    assert_true(pcall(DE.buildSettings, {}, DEST, nil), "buildSettings never raises on nil opts")
    assert_true(pcall(DE.buildSettings, nil, nil, nil), "buildSettings never raises on all-nil")

    local a = DE.buildSettings({}, DEST)
    local b = DE.buildSettings({}, DEST)
    assert_true(a ~= b, "buildSettings returns a fresh table each call (no shared identity)")
    a.LR_format = 'MUTATED'
    assert_eq(b.LR_format, 'JPEG', "mutating one result does not affect another (no shared state)")
end
