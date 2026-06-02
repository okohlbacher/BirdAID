-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/viz_report.lua (Phase 9 — BL-04 detection report glue)
--
-- THIN Lr-GLUE adapter. This file lives in the src/lr/ glue tier and MAY touch the Lightroom SDK
-- (LrPathUtils, LrFileUtils, LrStringUtils, LrHttp). It is NOT a pure module and is intentionally
-- EXCLUDED from the negative-purity grep gate (which scopes only the pure src/ modules). It is
-- loaded only by an entry point AFTER birdaid_bootstrap.lua has installed the require shim. ALL
-- decision-critical logic is PURE and lives elsewhere: the SVG body (src.viz.svg), the file:// URL
-- escaping (src.viz.file_url), the keyword label (src.keyword), and the temp-dir sweep policy
-- (src.crop.sweep). This layer is the thin SDK adapter: encode the preview, write the file, open it.
--
-- WHAT IT DOES (BL-04): compose the PURE svg.render output with the real SMALL preview bytes
-- (base64 data-URI) and open the result in the browser via a percent-escaped file:// URL.
--
-- TEMP OWNERSHIP (resolves the crop-OFF leak + the browser-load race; T-09-06):
--   * reportDir(runId)         -> <temp>/BirdAID/report-<sanitized-id>/ — a DEDICATED report dir
--                                 OWNED by this module, INDEPENDENT of the crop run-<id>/ dirs. It
--                                 reuses src.crop.sweep.sanitizeRunId so a bad runId can NEVER
--                                 escape <temp>/BirdAID/ (the same containment guard cropper uses).
--   * sweepOrphans(currentRunId)-> delete ONLY OTHER stale report-* dirs (age-gated via the same
--                                 sweep policy, skipping the CURRENT run's report dir) — mirroring
--                                 cropper.sweepOrphans. This reaps PRIOR runs' reports. CRITICAL
--                                 (SHOULD-FIX E): the ORCHESTRATOR (Wave 3) calls sweepOrphans at
--                                 RUN START *UNCONDITIONALLY* — regardless of the showDetectionReport
--                                 toggle — so report dirs from a prior report-ENABLED run cannot leak
--                                 across later report-DISABLED runs. This module only PROVIDES the
--                                 sweep; Wave 3 pins the unconditional run-start call.
--   * The CURRENT run's report is LEFT on disk (NO cleanup-handler delete): the browser needs the
--     file:// to keep existing while it loads, and deleting on context cleanup would race the
--     browser. The current report is a transient temp file that the NEXT run's (unconditional)
--     orphan-sweep reaps. Ownership: this module owns report-* dirs; the next run sweeps them
--     unconditionally; crop owns run-* dirs separately.
--
-- *** LIVE-UNVERIFIED ASSUMPTION (A-VIZ) ***
-- That LrHttp.openUrlInBrowser opens a file:// URL on macOS (the BL-04 spike DR-3a says yes; this
-- is UNPROVEN in-LrC here). The open is guarded in pcall; on failure we log a token-free warn and
-- RETURN the (never-logged) file PATH so the orchestrator can surface it for manual open — the
-- report file is still written either way.
--
-- PII / NO-LEAK (T-09-03/T-09-06): the data-URI contains the user's OWN image pixels (acceptable —
-- shown to the user locally), but the data-URI, the SVG body, the labels, and the raw file PATH
-- MUST NEVER reach a LOG line verbatim. We log only a token-free "report written" with the
-- report-dir LEAF + the detection COUNT. encodeBase64 blocks the main thread on large images, so
-- we encode ONLY the SMALL preview bytes already fetched (NEVER a full-res export) — documented
-- here and enforced by the caller passing preview bytes.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack global. MUST run
-- inside an LrTasks task (encodeBase64 / file IO); the caller owns the task + pcall isolation.

local LrPathUtils   = import 'LrPathUtils'
local LrFileUtils   = import 'LrFileUtils'
local LrStringUtils = import 'LrStringUtils'
local LrHttp        = import 'LrHttp'

local svg     = require 'src.viz.svg'
local fileUrl = require 'src.viz.file_url'
local keyword = require 'src.keyword'
local sweep   = require 'src.crop.sweep'
local gallery = require 'src.viz.gallery'   -- GAL-01: ONE combined page over N svg bodies
local log     = require 'src.log'

local M = {}

-- Age (seconds) above which an OTHER run's leftover report dir is considered stale + sweepable.
-- Matches cropper's STALE_THRESHOLD so a concurrent run's fresh report dir is never swept.
local STALE_THRESHOLD = 3600

-- ---------------------------------------------------------------------------
-- birdaidTempDir() -> <temp>/BirdAID  (the SHARED scratch parent; created if absent). Mirrors
-- cropper.birdaidTempDir so report-* and run-* dirs live under the same owned parent.
-- ---------------------------------------------------------------------------
function M.birdaidTempDir()
    local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'BirdAID')
    if not LrFileUtils.exists(dir) then
        LrFileUtils.createAllDirectories(dir)
    end
    return dir
end

-- reportDirName(runId) -> 'report-' .. sanitizeRunId(runId) | nil for an unsafe id. Distinct
-- prefix from cropper's 'run-' so the two ownerships never collide; reuses the SAME sanitizer so a
-- malicious/odd runId can never escape <temp>/BirdAID/.
function M.reportDirName(runId)
    local safe = sweep.sanitizeRunId(runId)
    if not safe then return nil end
    return 'report-' .. safe
end

-- isOurReportDir(name) -> true ONLY for a name shaped like our report-<id> dir (report- followed by
-- one or more [%w-_] chars, anchored). Rejects crop run-* dirs, foreign names, traversal.
function M.isOurReportDir(name)
    if type(name) ~= 'string' then return false end
    return name:match('^report%-[%w%-_]+$') ~= nil
end

-- reportDir(runId) -> <temp>/BirdAID/report-<sanitized-id>/ | (nil, 'bad-runId'). Created if absent.
function M.reportDir(runId)
    local name = M.reportDirName(runId)
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
-- sweepOrphans(currentRunId)  — delete ONLY OTHER stale report-* dirs (age-gated). NEVER the
-- current run's report dir; NEVER a crop run-* dir; NEVER a foreign file. A concurrent run's FRESH
-- report dir is below the age gate and is safe. Best-effort: every delete is pcall-wrapped and
-- never raises. MIRRORS cropper.sweepOrphans exactly (FAIL-SAFE: only a READABLE mtime that PROVES
-- staleness permits deletion; an unreadable mtime KEEPS the dir).
-- The ORCHESTRATOR calls this UNCONDITIONALLY at run start (regardless of showDetectionReport).
-- ---------------------------------------------------------------------------
function M.sweepOrphans(currentRunId)
    local dir = M.birdaidTempDir()
    local currentLeaf = M.reportDirName(currentRunId)   -- may be nil for an unsafe id
    local now = os.time()

    local ok = pcall(function()
        for entry in LrFileUtils.directoryEntries(dir) do
            local leaf = LrPathUtils.leafName(entry)

            -- ONLY our report-* dirs, and NEVER the current run's report dir.
            if leaf ~= currentLeaf and M.isOurReportDir(leaf) then
                local age            -- nil unless a readable mtime proves an age
                local okAttr, attr = pcall(function()
                    return LrFileUtils.fileAttributes(entry)
                end)
                if okAttr and type(attr) == 'table' and type(attr.fileModificationDate) == 'number' then
                    -- fileModificationDate is Cocoa-epoch seconds; os.time is Unix-epoch.
                    local cocoaNow = now - 978307200   -- Unix->Cocoa epoch offset (best-effort)
                    local a = cocoaNow - attr.fileModificationDate
                    if a == a then age = a end         -- NaN guard
                end

                -- Only when a confirmed age proves staleness do we delete; unknown mtime => keep.
                if type(age) == 'number' and age >= STALE_THRESHOLD then
                    pcall(function() LrFileUtils.delete(entry) end)
                end
            end
        end
    end)

    if not ok then
        log.warn("report orphan sweep skipped (non-fatal)", {
            runId = currentRunId, reason = 'sweep-error',
        })
    end
end

-- ---------------------------------------------------------------------------
-- dataUri(previewBytes) -> 'data:image/jpeg;base64,<...>' | nil. Base64-encodes the SMALL preview
-- bytes (NEVER a full-res export — encodeBase64 blocks the main thread on large images). nil/empty
-- bytes -> nil (svg.render then renders boxes over a blank canvas). The data-URI is NEVER logged.
-- ---------------------------------------------------------------------------
local function dataUri(previewBytes)
    if type(previewBytes) ~= 'string' or previewBytes == '' then
        return nil
    end
    local okEnc, b64 = pcall(function() return LrStringUtils.encodeBase64(previewBytes) end)
    if not okEnc or type(b64) ~= 'string' or b64 == '' then
        return nil
    end
    return 'data:image/jpeg;base64,' .. b64
end

-- ---------------------------------------------------------------------------
-- buildDetections(response, prefs) -> array of { bbox, label, title } for svg.render. PURE
-- composition over the contract-valid identify response: for each detection it derives the label
-- via the PURE keyword.render(keyword.decide(detection, prefs)) (the SAME rendering the catalog
-- write uses, so the report shows EXACTLY what would be written), and a hover title carrying the
-- species/confidence/rank. A detection with no renderable keyword still shows its box + a title.
-- ---------------------------------------------------------------------------
local function buildDetections(response, prefs)
    local out = {}
    if type(response) ~= 'table' or type(response.detections) ~= 'table' then
        return out
    end
    for di = 1, #response.detections do
        local d = response.detections[di]
        if type(d) == 'table' and type(d.bbox) == 'table' then
            -- Label: the rendered keyword (or a fallback to the common/scientific name).
            local label = keyword.render(keyword.decide(d, prefs))
            if type(label) ~= 'string' or label == '' then
                label = tostring(d.common_name or d.scientific_name or d.rank_name or 'bird')
            end
            -- Title (hover): species + confidence + rank, all from the response (svg.render escapes).
            local conf = tonumber(d.confidence)
            local confStr = (type(conf) == 'number' and conf == conf)
                and string.format('%.2f', conf) or '?'
            local title = tostring(d.common_name or d.scientific_name or 'bird')
                .. ' (' .. tostring(d.scientific_name or '?') .. ')'
                .. '  conf=' .. confStr
                .. '  rank=' .. tostring(d.identified_rank or d.rank_name or '?')
            out[#out + 1] = { bbox = d.bbox, label = label, title = title }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- writeAndOpen(opts) -> { path = <abs svg path>, opened = <bool>, detections = <n> } | (nil, reason)
--
-- opts = {
--   runId        = <string>,         -- run correlation id (drives the report dir name)
--   idx          = <number>,         -- per-photo index (drives the svg basename)
--   previewBytes = <jpeg bytes|nil>, -- the SMALL preview (base64'd into the data-URI); nil -> blank
--   frameW       = <number>,         -- parsed preview width
--   frameH       = <number>,         -- parsed preview height
--   response     = <contract-valid identify response>,
--   prefs        = <typed prefs>,    -- for keyword.decide (confidence threshold + promptAddition)
--   file         = <string>,         -- loggable formatted filename (token-free)
-- }
--
-- Renders the PURE SVG over the base64 preview, writes it into the dedicated report dir, builds a
-- PERCENT-ESCAPED file:// URL (src.viz.file_url, NO raw concat), and opens it via
-- LrHttp.openUrlInBrowser guarded in pcall. On open failure logs a token-free warn and returns the
-- path (opened=false) so the orchestrator can surface it for manual open. The report file is
-- written regardless. NEVER logs the path/data-URI/labels verbatim — only the report-dir leaf +
-- the detection count.
-- ---------------------------------------------------------------------------
function M.writeAndOpen(opts)
    opts = type(opts) == 'table' and opts or {}
    local runId = opts.runId
    local idx   = tonumber(opts.idx) or 0
    local file  = type(opts.file) == 'string' and opts.file or '(unknown file)'

    local dir, derr = M.reportDir(runId)
    if not dir then
        log.warn("report dir unavailable (skipping report for this photo)", {
            runId = runId, file = file, reason = tostring(derr),
        })
        return nil, derr
    end

    local detections = buildDetections(opts.response, opts.prefs)
    local svgStr = svg.render({
        frameW       = opts.frameW,
        frameH       = opts.frameH,
        imageDataUri = dataUri(opts.previewBytes),
        detections   = detections,
    })

    -- Write the SVG into the dedicated report dir (collision-safe basename per photo index).
    local basename = string.format('report-%05d.svg', idx)
    local outPath  = LrPathUtils.child(dir, basename)

    local f = io.open(outPath, 'wb')
    if not f then
        log.warn("report file write failed (skipping report for this photo)", {
            runId = runId, file = file, reason = 'report-write-failed',
        })
        return nil, 'report-write-failed'
    end
    f:write(svgStr)
    f:close()

    -- Build the PERCENT-ESCAPED file:// URL (PURE; NO raw concat) and open it (guarded).
    local url = fileUrl.pathToFileUrl(outPath)
    local opened = false
    if url then
        local okOpen = pcall(function() LrHttp.openUrlInBrowser(url) end)
        opened = okOpen and true or false
    end

    if not opened then
        -- A-VIZ fallback: the report file is written; the open failed (or the path was unescapable).
        -- Surface the PATH to the orchestrator (returned, NOT logged) for manual open. Token-free log.
        log.warn("report written but could not open in browser (open it manually from the path)", {
            runId = runId, file = file,
            reportLeaf = M.reportDirName(runId), detections = #detections,
        })
    else
        log.info("report written + opened in browser", {
            runId = runId, file = file,
            reportLeaf = M.reportDirName(runId), detections = #detections,
        })
    end

    return { path = outPath, opened = opened, detections = #detections }
end

-- ---------------------------------------------------------------------------
-- writeGalleryAndOpen(opts) -> { path = <abs gallery path>, opened = <bool>, photos = <n> } | (nil, reason)
--
-- GAL-01: write ONE combined gallery page (regardless of selection size — the 20-tab cap is gone)
-- and open ONE browser tab. Mirrors writeAndOpen EXACTLY (write -> percent-escaped file:// via
-- fileUrl.pathToFileUrl, NO raw concat -> guarded open -> token-free warn + RETURN path on failure)
-- but renders the COMBINED gallery.render(photos) instead of one per-photo svg.
--
-- opts = {
--   runId  = <string>,        -- run correlation id (drives the report dir name)
--   prefs  = <typed prefs>,   -- for keyword.decide (confidence threshold + promptAddition)
--   photos = {                -- one entry per DETECTED photo, in selection order
--     { previewBytes = <jpeg bytes|nil>,  -- the SMALL preview ALREADY fetched in the main pass
--       frameW = <number>, frameH = <number>,  -- parsed preview dims (carried forward; NO re-fetch)
--       response = <contract-valid identify response>,
--       file = <string> },    -- loggable formatted filename (token-free); used as the section label
--     ...
--   },
-- }
--
-- THRU-01 / CODEX MEDIUM-3: previewBytes are CARRIED FORWARD from the main fetch — this function
-- NEVER re-fetches a preview. A photo whose bytes were not retained renders without a base image
-- (gallery handles a nil uri). It REUSES dataUri (jpeg base64) + buildDetections (the SAME keyword
-- rendering the catalog write uses) so the gallery shows EXACTLY what would be written.
-- ---------------------------------------------------------------------------
function M.writeGalleryAndOpen(opts)
    opts = type(opts) == 'table' and opts or {}
    local runId = opts.runId
    local prefs = opts.prefs
    local photosIn = type(opts.photos) == 'table' and opts.photos or {}

    local dir, derr = M.reportDir(runId)
    if not dir then
        log.warn("report dir unavailable (skipping gallery)", {
            runId = runId, reason = tostring(derr),
        })
        return nil, derr
    end

    -- Assemble the PURE gallery input array: each section carries the vetted-by-gallery raster
    -- data-URI (from the carried-forward preview bytes), the parsed dims, the per-detection labels,
    -- and the token-free file label. The gallery itself xml-escapes every dynamic string.
    local galleryPhotos = {}
    for i = 1, #photosIn do
        local p = photosIn[i]
        if type(p) == 'table' then
            galleryPhotos[#galleryPhotos + 1] = {
                frameW       = p.frameW,
                frameH       = p.frameH,
                imageDataUri = dataUri(p.previewBytes),   -- nil when bytes were not retained (no re-fetch)
                detections   = buildDetections(p.response, prefs),
                label        = type(p.file) == 'string' and p.file or '(unknown file)',
            }
        end
    end

    local htmlStr = gallery.render(galleryPhotos)

    -- Write the ONE combined gallery file into the dedicated report dir.
    local outPath = LrPathUtils.child(dir, 'gallery.html')
    local f = io.open(outPath, 'wb')
    if not f then
        log.warn("gallery file write failed (skipping report)", {
            runId = runId, reason = 'gallery-write-failed',
        })
        return nil, 'gallery-write-failed'
    end
    f:write(htmlStr)
    f:close()

    -- Build the PERCENT-ESCAPED file:// URL (PURE; NO raw concat) and open it ONCE (guarded).
    local url = fileUrl.pathToFileUrl(outPath)
    local opened = false
    if url then
        local okOpen = pcall(function() LrHttp.openUrlInBrowser(url) end)
        opened = okOpen and true or false
    end

    if not opened then
        -- A-VIZ fallback: the gallery file is written; the open failed (or the path was unescapable).
        -- Surface the PATH to the orchestrator (returned, NOT logged) for manual open. Token-free log.
        log.warn("gallery written but could not open in browser (open it manually from the path)", {
            runId = runId, reportLeaf = M.reportDirName(runId), photos = #galleryPhotos,
        })
    else
        log.info("gallery written + opened in browser", {
            runId = runId, reportLeaf = M.reportDirName(runId), photos = #galleryPhotos,
        })
    end

    return { path = outPath, opened = opened, photos = #galleryPhotos }
end

return M
