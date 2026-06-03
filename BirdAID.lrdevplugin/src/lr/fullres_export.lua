-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/fullres_export.lua (Phase 13 Plan 03 — DEEP-03 full-res export glue)
--
-- THIN Lr-GLUE adapter. This file lives in the src/lr/ glue tier and MAY touch the
-- Lightroom SDK (LrExportSession, LrFileUtils, LrPathUtils). It is NOT pure and is
-- intentionally EXCLUDED from the negative-purity grep gate (which scopes only the pure
-- src/ modules). It is loaded only by an entry point AFTER birdaid_bootstrap.lua has
-- installed the require shim.
--
-- export(photo, opts) -> renderedPath | (nil, reason)
--   opts = {
--     destDir = <string>,   -- the per-run temp dir prefix (PII path; NEVER logged)
--     index   = <number>,   -- per-photo index -> sweep.tempNames(index).export basename
--     prefs   = <table>,    -- normalized prefs (passed to deep_export.buildSettings)
--     maxEdge = <number>,   -- optional: 2048 (OpenAI-equiv) | nil (unconstrained full-res)
--     file    = <string>,   -- optional FORMATTED filename for logs (loggable; NEVER the path)
--     runId   = <string>,   -- run correlation id for logs
--   }
--   reason = 'no-rendition' | 'render-failed' | 'export-init-failed' | 'no-dest'
--
-- This is the heavy full-res evidence render: it consumes the PURE deep_export.buildSettings
-- table (13-01) and runs LrExportSession against it, returning the rendered full-res JPEG path.
-- It re-derives NO LR_* table inline (the settings shape decision lives wholly in deep_export).
--
-- HARD INVARIANTS (13-RESEARCH Pattern 2 + Pitfalls 1-4 / CLAUDE.md):
--   * MUST run on an LrTasks task (waitForRender BLOCKS until rendered). The CALLER owns the
--     task + the per-photo LrTasks.pcall isolation (yield-safe; standard pcall forbids yielding
--     across the C-frame). This module calls waitForRender directly inside the renditions loop.
--   * MUST NOT be reachable from inside a withWriteAccessDo gate — a heavy Develop render in the
--     write window expands Undo coalescing/contention (Pitfall 2). All export work is OUTSIDE
--     the gate (the 13-04 loop collects results, then writes once).
--   * Per-photo isolation: a render failure returns (nil, reason); the caller skips this photo
--     and the run continues. This module never raises for a normal failure.
--   * The 13-01 settings table strips GPS/EXIF (LR_removeLocationMetadata / minimizeEmbedded),
--     so the temp JPEG carries no location metadata (T-13-09).
--
-- T-13-06 (no path PII in logs): log ONLY the FORMATTED filename (opts.file) + the sweep
-- basename + runId/counts. NEVER the raw temp path, the token, or a body.
--
-- Strictly Lua 5.1 common subset: no //, no goto, no <close>; UTF-8 literal bytes.

-- Defensive Lr imports (mirror preview_fetch's pattern): the bare SDK-load call is wrapped so a
-- module-load under stock lua (offline) does not hard-fail before the THIN banner is even read.
local LrExportSession
local LrFileUtils
local LrPathUtils
pcall(function() LrExportSession = import 'LrExportSession' end)
pcall(function() LrFileUtils     = import 'LrFileUtils' end)
pcall(function() LrPathUtils     = import 'LrPathUtils' end)

local deep_export = require 'src.deep_export'   -- PURE LR_* settings builder (13-01)
local sweep       = require 'src.crop.sweep'    -- PURE per-run dir + export-<NNNNN>.jpg basename
local log         = require 'src.log'           -- single redacting sink; token/path-free fields

local M = {}

-- export(photo, opts) -> renderedPath | (nil, reason)
-- Renders a single full-res (or 2048-equiv) JPEG to the per-run temp dir and returns its path.
-- Precondition: MUST be called on an LrTasks task, OUTSIDE any withWriteAccessDo gate. The caller
-- isolates a throw with LrTasks.pcall (yield-safe). NEVER logs the path/token/body.
function M.export(photo, opts)
    opts = opts or {}
    local file    = type(opts.file) == 'string' and opts.file or '(unknown file)'
    local runId   = opts.runId
    local destDir = opts.destDir
    local index   = type(opts.index) == 'number' and opts.index or 0

    if type(destDir) ~= 'string' or destDir == '' then
        -- No destination -> nothing to render to. Token/path-free (destDir is empty here).
        log.warn('deep export skipped: no destination dir (run continues)', {
            runId = runId, file = file, reason = 'no-dest',
        })
        return nil, 'no-dest'
    end

    -- The collision-safe basename (export-<NNNNN>.jpg) is loggable (it is NOT the raw path).
    local basename = sweep.tempNames(index).export

    -- Consume the PURE settings builder (13-01): unconstrained full-res when maxEdge is nil,
    -- the OpenAI 2048-equiv when maxEdge is a number. NO inline LR_* re-derivation here.
    local exportSettings = deep_export.buildSettings(opts.prefs, destDir, { maxEdge = opts.maxEdge })

    -- Ensure the per-run dir exists (idempotent). Defensive: a createAllDirectories failure is
    -- non-fatal here — the export below will surface a render failure cleanly if the dir is bad.
    if LrFileUtils and LrFileUtils.createAllDirectories then
        pcall(function() LrFileUtils.createAllDirectories(destDir) end)
    end

    -- Construct the session. Guard the INITIATION with a standard pcall: building the session is
    -- not a yielding call (the yielding work is waitForRender below, which is NOT inside this
    -- pcall). A construction raise becomes a clean (nil, reason) so per-photo isolation holds.
    local okInit, session = pcall(function()
        return LrExportSession({
            photosToExport = { photo },
            exportSettings = exportSettings,
        })
    end)
    if not okInit or session == nil then
        log.warn('deep export session init failed (skipping photo; run continues)', {
            runId = runId, file = file, basename = basename, reason = 'export-init-failed',
            error = tostring(session),
        })
        return nil, 'export-init-failed'
    end

    -- Drive the renditions. waitForRender BLOCKS until the frame is rendered to disk; it YIELDS
    -- the cooperative task while it works, so this loop MUST run on an LrTasks task (caller's
    -- precondition) and is NOT wrapped here in a standard pcall (yield-across-C-frame; Pitfall 4).
    -- The caller's LrTasks.pcall isolates a throw. On ok we return the rendered path; on a render
    -- error we return (nil, 'render-failed') and the caller skips this photo (run continues).
    local renderError
    for rendition in session:renditions() do
        local ok, pathOrMessage = rendition:waitForRender()
        if ok then
            -- pathOrMessage is the rendered full-res path. It is PII — NEVER logged. Return it
            -- to the caller (which streams it by filePath via http.uploadFile, then deletes it).
            return pathOrMessage
        end
        -- pathOrMessage is the SDK's render message. It can carry a path; do NOT log it verbatim.
        renderError = 'render-failed'
    end

    if renderError then
        log.warn('deep export render failed (skipping photo; run continues)', {
            runId = runId, file = file, basename = basename, reason = renderError,
        })
        return nil, renderError
    end

    -- The session produced no rendition at all (unexpected). Token/path-free.
    log.warn('deep export produced no rendition (skipping photo; run continues)', {
        runId = runId, file = file, basename = basename, reason = 'no-rendition',
    })
    return nil, 'no-rendition'
end

return M
