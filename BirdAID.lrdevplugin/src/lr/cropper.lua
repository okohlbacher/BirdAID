-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/cropper.lua (Phase 6 — Crop-for-ID, CROP-01/02/05 GLUE)
--
-- *** PROVISIONAL — pending the Wave-3 in-LrC spike (06-03) ***
-- This module is WRITTEN FROM RESEARCH (06-RESEARCH Patterns 1/2/4/8) but is explicitly
-- PROVISIONAL: three assumptions are NOT yet confirmed on real photos and MUST be validated
-- by the spike before the phase may be approved:
--   * A1 — preview/export coordinate identity (a normalized bbox vs the preview frame maps
--          to the EXPORT frame by simple scale, on a portrait EXIF-rotated AND a
--          develop-cropped photo). bbox_transform consumes the EXPORT dims read here.
--   * A2 — macOS shell quoting / the whole-command form fed to LrTasks.execute.
--   * A5 — the EXACT LrExportSession key names/values in exportFullRes (LR_* below).
-- If the spike shows A1/A2/A5 require changes, this glue MUST be corrected first.
--
-- THIN Lr-GLUE adapter. This file lives in the src/lr/ glue tier and MAY touch the
-- Lightroom SDK (LrExportSession, LrTasks, LrFileUtils, LrPathUtils). It is NOT pure and is
-- intentionally EXCLUDED from the negative-purity grep gate (which scopes only the pure
-- src/ modules). It is loaded only by an entry point AFTER birdaid_bootstrap.lua has
-- installed the require shim. All decision-critical logic (bbox->rect, command building,
-- exit decode, sweep policy) lives in the PURE src/crop/* modules from 06-01; this layer is
-- the thin SDK adapter.
--
-- It owns, for the opt-in crop pass:
--   * birdaidTempDir() — the SHARED scratch parent <temp>/BirdAID/.
--   * runDir(runId)    — the PER-RUN OWNED subdir <temp>/BirdAID/run-<sanitized-id>/. Every
--                        export/crop/err file for the run lives inside it (the run DIR is the
--                        ownership marker; see src.crop.sweep).
--   * exportFullRes(photo, runId, idx) — LrExportSession full-res JPEG into the run dir.
--   * exportDims(path)  — read the EXPORT JPEG's ACTUAL decoded dims (the EXACT crop ref).
--   * validateToolPath(toolPath) — FAIL CLOSED unless absolute + non-leading-dash + exists.
--   * runCrop(...)      — cropcmd.build -> LrTasks.execute -> cropcmd.decodeExit (raw==0 only).
--   * sweepOrphans(currentRunId) — delete ONLY OTHER stale run-* dirs (age-gated; never the
--                                  current run; never foreign files).
--   * cleanupRunDir(runId) — delete the WHOLE per-run dir (success/error/cancel handler).
--
-- TIMEOUT (CODEX #5 / A7): LrTasks.execute has NO native per-exec timeout, and the SDK
-- exposes no timeout primitive. We ACCEPT blocking for v1 — the input is a JPEG we just
-- wrote, and the caller checks cancellation BETWEEN photos (NOT mid-exec). A watchdog is
-- documented FUTURE WORK. We do NOT claim a working timeout anywhere.
--
-- PII / NO-LEAK (CODEX #6/T-06-06): NEVER log the raw input/crop path, the command, the
-- token, GPS/date, or stderr VERBATIM (stderr may echo the raw path). Log a SANITIZED reason
-- token + the run leaf + the exit code + a stderr LENGTH only. The redaction sink is a
-- backstop.
--
-- Strictly Lua 5.1 common subset: no //, no goto, no <close>; unpack is global.

local LrExportSession = import 'LrExportSession'
local LrPathUtils     = import 'LrPathUtils'
local LrFileUtils     = import 'LrFileUtils'
local LrTasks         = import 'LrTasks'

local cropcmd = require 'src.crop.cropcmd'
local sweep   = require 'src.crop.sweep'
local preview = require 'src.preview'
local log     = require 'src.log'

local M = {}

-- Age (seconds) above which an OTHER run's leftover dir is considered stale + sweepable.
-- An hour is comfortably longer than any single run, so a CONCURRENT run's fresh dir is
-- never swept (its age is far below this gate).
local STALE_THRESHOLD = 3600

-- ---------------------------------------------------------------------------
-- birdaidTempDir() -> <temp>/BirdAID  (the SHARED scratch parent; created if absent).
-- ---------------------------------------------------------------------------
function M.birdaidTempDir()
    local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'BirdAID')
    if not LrFileUtils.exists(dir) then
        LrFileUtils.createAllDirectories(dir)
    end
    return dir
end

-- ---------------------------------------------------------------------------
-- runDir(runId) -> <temp>/BirdAID/run-<sanitized-id>/  | (nil, 'bad-runId')   [CODEX #6/#7]
-- sweep.runDirName rejects an unsafe runId (separators, '..', control chars), so a malicious
-- or odd runId can never escape <temp>/BirdAID/. The dir is created if absent.
-- ---------------------------------------------------------------------------
function M.runDir(runId)
    local name = sweep.runDirName(runId)
    if not name then
        return nil, 'bad-runId'
    end
    local dir = LrPathUtils.child(M.birdaidTempDir(), name)
    if not LrFileUtils.exists(dir) then
        LrFileUtils.createAllDirectories(dir)
    end
    return dir
end

-- ---------------------------------------------------------------------------
-- exportFullRes(photo, runId, idx) -> exportedPath | (nil, err)
--
-- Exports the full-resolution frame as JPEG into the PER-RUN owned dir. The export lands in
-- the run dir so sweep.isOurs (run-dir naming) governs its cleanup.
--
-- *** A5 PROVISIONAL: the LR_* export-setting key NAMES/VALUES below are written from
-- 06-RESEARCH and are PENDING the Wave-3 spike. The canonical way to confirm them is to make
-- an Export preset in LrC and read its .lrtemplate. DO NOT treat these as confirmed. ***
-- ---------------------------------------------------------------------------
function M.exportFullRes(photo, runId, idx)
    local outDir, derr = M.runDir(runId)
    if not outDir then
        return nil, derr
    end

    local exportSettings = {
        -- A5 PROVISIONAL key set:
        LR_export_destinationType       = 'specificFolder', -- else export lands on the desktop
        LR_export_destinationPathPrefix = outDir,           -- the PER-RUN owned dir
        LR_export_useSubfolder          = false,
        LR_format                       = 'JPEG',
        LR_jpeg_quality                 = 0.92,             -- 0..1 (confirm scale in the spike)
        LR_size_doConstrain             = false,            -- FULL resolution (no resize)
        LR_collisionHandling            = 'rename',         -- never clobber
        LR_minimizeEmbeddedMetadata     = true,             -- transient input; strip extras
        LR_removeLocationMetadata       = true,             -- belt-and-braces privacy on the temp
        LR_reimportExportedPhoto        = false,            -- NEVER add the temp back to the catalog
    }

    local session = LrExportSession({
        photosToExport = { photo },
        exportSettings = exportSettings,
    })

    session:doExportOnCurrentTask()                          -- blocks THIS task only (we are in one)

    for rendition in session:renditions() do
        local ok, pathOrMessage = rendition:waitForRender()  -- (success, pathOrMessage)
        if ok then
            return pathOrMessage                             -- == rendition.destinationPath
        end
        -- pathOrMessage is the error MESSAGE on failure; do NOT log it raw (may carry a path).
        return nil, 'export-failed'
    end

    return nil, 'no-rendition'
end

-- ---------------------------------------------------------------------------
-- exportDims(path) -> (w, h) | (nil, err)
-- Read the EXPORTED JPEG's ACTUAL decoded dims — the EXACT crop reference (NEVER the preview
-- dims). PURE parseJpegDims does the work; the only glue here is the file read.
-- ---------------------------------------------------------------------------
function M.exportDims(path)
    local f = io.open(path, 'rb')
    if not f then
        return nil, 'export-read-failed'
    end
    local bytes = f:read('*a')
    f:close()
    if type(bytes) ~= 'string' or bytes == '' then
        return nil, 'export-read-failed'
    end
    return preview.parseJpegDims(bytes)
end

-- ---------------------------------------------------------------------------
-- validateToolPath(toolPath) -> (true) | (false, 'tool-missing')             [CODEX #2]
-- FAIL CLOSED unless the path is a non-empty ABSOLUTE string (begins with '/'), is NOT
-- option-like (no leading '-'), AND LrFileUtils.exists. No PATH reliance. Token-free reason.
-- ---------------------------------------------------------------------------
function M.validateToolPath(toolPath)
    if type(toolPath) ~= 'string' or toolPath == '' then return false, 'tool-missing' end
    if toolPath:sub(1, 1) == '-' then return false, 'tool-missing' end  -- option-like -> reject
    if toolPath:sub(1, 1) ~= '/' then return false, 'tool-missing' end  -- relative -> reject
    if not LrFileUtils.exists(toolPath) then return false, 'tool-missing' end
    return true
end

-- ---------------------------------------------------------------------------
-- runCrop(toolPath, inPath, rect, runId, idx, file, maxEdge) -> outPath | (nil, reason)
--
-- Validate the tool (fail-closed) -> build the command via the PURE cropcmd.build -> exec via
-- LrTasks.execute -> decode the raw status via cropcmd.decodeExit (success ONLY when raw==0,
-- never the divide-by-256 high-byte masking) -> read stderr from the redirect file. On
-- success delete the err file and
-- return the crop path. On any failure log a SANITIZED, token-free warn (reason + run leaf +
-- exit + stderr LENGTH only; NEVER the path/command/stderr-verbatim) and return (nil, reason).
-- ---------------------------------------------------------------------------
function M.runCrop(toolPath, inPath, rect, runId, idx, file, maxEdge)
    local okTool, why = M.validateToolPath(toolPath)
    if not okTool then
        log.warn("crop tool unavailable (skipping crop; using preview result)", {
            runId = runId, file = file, reason = why,
        })
        return nil, why
    end

    local dir, derr = M.runDir(runId)
    if not dir then
        log.warn("crop run dir unavailable (skipping crop; using preview result)", {
            runId = runId, file = file, reason = derr,
        })
        return nil, derr
    end

    local names   = sweep.tempNames(idx)
    local outPath = LrPathUtils.child(dir, names.crop)
    local errPath = LrPathUtils.child(dir, names.err)

    local cmd, cerr = cropcmd.build(toolPath, inPath, rect, outPath, errPath, maxEdge)
    if not cmd then
        log.warn("crop command not built (skipping crop; using preview result)", {
            runId = runId, file = file, reason = cerr,
        })
        return nil, cerr
    end

    -- EXECUTE. LrTasks.execute blocks ONLY this task and returns the RAW OS shell status.
    -- NO native timeout (see header) — cancellation is between photos, not mid-exec.
    local raw = LrTasks.execute(cmd)
    local okExit, exit = cropcmd.decodeExit(raw)   -- raw==0 only (CODEX #4)

    -- Capture stderr (LrTasks.execute returns ONLY the status; stderr was redirected to file).
    -- We NEVER log it verbatim (it may echo the raw path) — only its LENGTH.
    local stderr = ''
    local ef = io.open(errPath, 'r')
    if ef then
        stderr = ef:read('*a') or ''
        ef:close()
    end

    if okExit and LrFileUtils.exists(outPath) then
        -- Delete the now-useless err file on success (the whole run dir is cleaned later too).
        pcall(function() LrFileUtils.delete(errPath) end)
        return outPath
    end

    log.warn("crop tool failed (skipping crop; using preview result)", {
        runId = runId, file = file, reason = 'crop-failed', exit = exit,
        stderrLen = #stderr,        -- LENGTH only; never the verbatim stderr / raw path.
    })
    return nil, 'crop-failed'
end

-- ---------------------------------------------------------------------------
-- sweepOrphans(currentRunId)                                       [CODEX #6/#7/#8/#9]
-- Delete ONLY OTHER stale run-* dirs (age-gated via sweep.isStaleRunDir). NEVER the current
-- run's dir; NEVER a foreign file. A concurrent run's FRESH dir is below the age gate and is
-- safe. Best-effort: every delete is pcall-wrapped and never raises.
-- ---------------------------------------------------------------------------
function M.sweepOrphans(currentRunId)
    local dir = M.birdaidTempDir()
    local currentLeaf = sweep.runDirName(currentRunId)   -- may be nil for an unsafe id
    local now = os.time()

    local ok = pcall(function()
        for entry in LrFileUtils.directoryEntries(dir) do
            local leaf = LrPathUtils.leafName(entry)

            -- Skip the CURRENT run's dir outright (never sweep ourselves).
            if leaf ~= currentLeaf and sweep.isOurs(leaf) then
                -- FAIL SAFE [CODEX #2]: we delete ONLY when a READABLE mtime PROVES the dir is
                -- older than STALE_THRESHOLD. If fileAttributes errors or omits a numeric
                -- fileModificationDate, staleness CANNOT be confirmed -> we KEEP the dir (do NOT
                -- treat unknown mtime as stale). This prevents wiping a concurrent run's dir
                -- whose attributes momentarily failed to read.
                local age            -- nil unless a readable mtime proves an age
                local okAttr, attr = pcall(function()
                    return LrFileUtils.fileAttributes(entry)
                end)
                if okAttr and type(attr) == 'table' and type(attr.fileModificationDate) == 'number' then
                    -- fileModificationDate is Cocoa-epoch seconds; os.time is Unix-epoch.
                    -- We do NOT need an exact age, only "older than STALE_THRESHOLD".
                    local cocoaNow = now - 978307200   -- Unix->Cocoa epoch offset (best-effort)
                    local a = cocoaNow - attr.fileModificationDate
                    if a == a then age = a end          -- NaN guard
                end

                -- Only when age is a confirmed number do we even consider deletion; unknown
                -- mtime => keep (fail safe).
                if type(age) == 'number' and sweep.isStaleRunDir(leaf, age, STALE_THRESHOLD) then
                    pcall(function() LrFileUtils.delete(entry) end)
                end
            end
        end
    end)

    if not ok then
        -- The sweep is best-effort housekeeping; never let it abort a run.
        log.warn("orphan sweep skipped (non-fatal)", { runId = currentRunId, reason = 'sweep-error' })
    end
end

-- ---------------------------------------------------------------------------
-- cleanupRunDir(runId) — delete the WHOLE per-run dir (immediate, NOT moveToTrash). Used by
-- the entry's addCleanupHandler so success/error/cancel ALL clean up. Best-effort.
-- ---------------------------------------------------------------------------
function M.cleanupRunDir(runId)
    local name = sweep.runDirName(runId)
    if not name then return end
    local dir = LrPathUtils.child(M.birdaidTempDir(), name)
    pcall(function() LrFileUtils.delete(dir) end)
end

return M
