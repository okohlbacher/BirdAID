-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/deep_export.lua (Phase 13 Plan 01 — DEEP-03 export-settings builder)
--
-- PURE module: it pulls in no Lightroom SDK namespace at load time, so it is require-able
-- under stock lua / lua5.1 / luajit for offline unit testing (the CODEX-mandated separation
-- invariant; the no-Lr purity grep stays clean). The bare SDK-load token is NEVER written
-- here, even in comments, because the purity grep false-positives on it.
--
-- buildSettings(prefs, destPath, opts) -> the LR_* settings TABLE that LrExportSession consumes
-- for a single full-res frame export to a per-run temp dir. This builder is pure table
-- composition ONLY: it constructs no session, runs no render, performs no I/O. The heavy
-- LrExportSession glue (which feeds this table in) is 13-03; keeping the table-shape decision
-- here makes that glue a thin pass-through and proves the field values offline.
--
-- Per-provider export policy (13-CONTEXT D-01 / D-01-OPENAI / D-02):
--   * Files-API providers (Anthropic/Gemini): UNCONSTRAINED full-res frame
--       -> LR_size_doConstrain = false   (send the deepest evidence the provider can use)
--   * OpenAI default: a ~2048px frame (the server auto-downscales any image to <=2048px and
--     exposes no file slot, so more pixels are wasted; the deep gain is detail:high tiling)
--       -> opts.maxEdge = 2048 sets LR_size_doConstrain = true + LR_size_maxWidth/Height.
--   * Both: JPEG (D-02), quality 0.8 (D-02), sRGB color space; LR_reimportExportedPhoto = false
--     (the temp export is transient, NEVER re-imported into the catalog); GPS/EXIF stripped via
--     LR_removeLocationMetadata + LR_minimizeEmbeddedMetadata (data minimization, T-13-02).
--
-- destPath is the per-run temp dir prefix (a PII temp path). This module is PURE DATA only:
-- it never logs and imports no log sink, so the path cannot leak from here (the glue owns logging).
--
-- Strictly Lua 5.1 common subset: no //, no goto, no <close>; unpack is global.

local M = {}

-- buildSettings(prefs, destPath, opts) -> a FRESH LR_* table each call (no shared mutable state).
--   prefs    : the normalized prefs table (currently unused for field values, reserved for future
--              quality/format overrides; accepted + ignored-if-nil so callers stay uniform).
--   destPath : the per-run temp dir prefix -> LR_export_destinationPathPrefix.
--   opts     : optional { maxEdge = <number> }. When maxEdge is a number, emit the constrained
--              (OpenAI 2048-equiv) variant; otherwise the unconstrained full-res variant.
-- NEVER raises on nil prefs / nil opts.
function M.buildSettings(prefs, destPath, opts)
    if type(opts) ~= 'table' then opts = {} end

    local s = {
        -- Destination: a specific temp folder, no extra subfolder, rename on collision.
        LR_export_destinationType       = 'specificFolder',
        LR_export_destinationPathPrefix = destPath,
        LR_export_useSubfolder          = false,
        LR_collisionHandling            = 'rename',
        -- Format & quality (D-02): JPEG, quality 0.8, sRGB. Small, fast-uploading, correct color.
        LR_format                       = 'JPEG',
        LR_jpeg_quality                 = 0.8,
        LR_export_colorSpaceName        = 'sRGB',
        -- Transient temp export — NEVER re-imported into the catalog.
        LR_reimportExportedPhoto        = false,
        -- Data minimization (T-13-02): strip GPS/EXIF from the exported JPEG.
        LR_minimizeEmbeddedMetadata     = true,
        LR_removeLocationMetadata       = true,
    }

    -- A5 / live-verified-in-13-05: the LR_size_* key names (LR_size_doConstrain / LR_size_maxWidth /
    -- LR_size_maxHeight) are LOW-confidence from research and MUST be confirmed against a live
    -- LrExportSession in 13-05. The branch logic (constrain only when a maxEdge is given) is stable.
    if type(opts.maxEdge) == 'number' then
        s.LR_size_doConstrain = true
        s.LR_size_maxWidth    = opts.maxEdge
        s.LR_size_maxHeight   = opts.maxEdge
    else
        s.LR_size_doConstrain = false
    end

    return s
end

return M
