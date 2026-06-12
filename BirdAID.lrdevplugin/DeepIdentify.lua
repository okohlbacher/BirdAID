-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/DeepIdentify.lua (Phase 13 Plan 04 — DEEP-03 manual "Deep identify…" command)
--
-- The ALWAYS-AVAILABLE manual deep-ID menu entry point (ADR-002 / D-04). Lightroom invokes it
-- from Library > Plug-in Extras > "Deep identify…". It is a CLONE of the proven IdentifyBirds.lua
-- lifecycle, re-pointed at the FULL-RES EVIDENCE path:
--   settings -> http.buildDeps(prefs.provider) -> providers.get(prefs.provider, deps)
--   -> per-photo (full-res EXPORT -> upload/inline -> provider identify -> provider-copy DELETE)
--   -> writeplan.planReport -> dry-run-log OR a single batched catalog_writer.apply.
--
-- It hangs off the SAME proven lifecycle anchors as IdentifyBirds.lua:
--   * Runs inside LrFunctionContext.postAsyncTaskWithContext so the UI thread never blocks and
--     cleanup/error handlers are context-bound (attachErrorDialogToFunctionContext).
--   * Reports the count of catalog:getTargetPhotos() it will act on (selection, else filmstrip).
--   * Drives a context-bound LrProgressScope; cancel is honored via progress:isCanceled().
--   * Isolates per-photo failures with LrTasks.pcall so a failing photo never aborts the run.
--   * Guarantees progress:done() AND the per-run temp-dir teardown run on normal completion,
--     cancel, AND unexpected error via context:addCleanupHandler (TWO handlers — Pattern 4).
--
-- ============================================================================
-- DEEP LOOP — the full-res evidence pass (13-CONTEXT D-01-OPENAI / D-01b / D-03 / D-04)
-- ============================================================================
--   * SEPARATE EXPORT CAP (D-03): the deep loop drives staged_pool.run at
--     maxConcurrency = normalizedPrefs.deepExportConcurrency (clamped 1..4, default 2) — NEVER the
--     AI prefs.maxConcurrency. Concurrent full-res EXPORTS are the exact risk class v1's
--     preview-timeout cliff warned about (BL-06), so this cap is its own knob.
--   * PRODUCER (fetchJob, MAIN-TASK serial): fullres_export.export renders a temp JPEG to the
--     per-run dir. OpenAI exports a ~2048-equiv frame (maxEdge=2048, D-01-OPENAI: chat-completions
--     downscales to <=2048 and exposes no file slot, so the gain is high-detail TILING, not pixels);
--     Anthropic/Gemini export an unconstrained full-res frame (maxEdge=nil) for the Files-API upload.
--   * CONSUMER (identifyJob): builds the `image` slot then calls the provider INSIDE an LrTasks.pcall.
--       - OpenAI: attach the exported frame inline (http.attachImage from the file path) and set
--         image.detail='high' (D-01-OPENAI high-detail tiling on the inline 2048 frame).
--       - Anthropic/Gemini: http.uploadFile(provider, path, deps) streams the temp file BY PATH
--         (no main-thread base64, D-01a) and yields a Files-API handle; set image.fileId/image.fileUri
--         so the PURE request builder (13-02) emits the file source.
--     AFTER the pcall, in a FINALLY-EQUIVALENT block reached on BOTH the ok AND the error branch,
--     http.deleteFile(provider, handle, deps) removes the Anthropic provider-side copy (D-01b: the
--     copy MUST be deleted on success AND failure; Gemini is a no-op, 48h auto-expiry).
--   * COLLECT entirely OUTSIDE any write gate, then writeplan.planReport -> dry-run-log OR a single
--     batched catalogWriter.apply (no export/upload/network inside withWriteAccessDo — Pitfall 2).
--   * TEMP TEARDOWN: a context:addCleanupHandler deletes the WHOLE per-run temp dir on success/error/
--     cancel/breaker; a STARTUP REAPER age-gates and removes stale leftover per-run dirs from a prior
--     crash (sweep.isStaleRunDir, isOurs ^run%- AND age >= 6h), SKIPPING this run's own dir.
--
-- SC1 EXPORT-CONCURRENCY-CLIFF SPIKE (pref-guarded; 13-05 toggles it): when rawPrefs.deepConcurrencySpike
-- is true the SAME run varies the export cap across the selection and records wall time + render
-- failures + peakConcurrency to the log so the recommended default can be tuned against the measured
-- render cliff. When the pref is false/nil the spike code is INERT. There is NO separate dev-harness
-- entry and NO forbidden dev-token anywhere in this file (the recursive dist gate stays clean).
--
-- This file imports Lr* (it is an orchestration entry) but it does NOT create its own logger — ALL
-- logging routes through the single src.log sink (single-sink invariant), and it NEVER logs the API
-- token, "Bearer", the request body / data URL, GPS, date, or the raw path (or the export temp path)
-- — only runId + counts + provider + the FORMATTED filename + peakConcurrency.
--
-- Strictly Lua 5.1 common subset (no goto, no //, no \u{}, no <close>).

local LrApplication     = import 'LrApplication'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'
local LrTasks           = import 'LrTasks'
local LrDialogs         = import 'LrDialogs'
local LrPathUtils       = import 'LrPathUtils'
local LrFileUtils       = import 'LrFileUtils'
local LrPrefs           = import 'LrPrefs'
local LrDate            = import 'LrDate'

-- Install the src.* module loader shim BEFORE any require of our modules: LrC's built-in require
-- cannot resolve dotted/subdirectory names. dofile is the documented escape hatch (CLAUDE.md).
dofile(LrPathUtils.child(_PLUGIN.path, 'birdaid_bootstrap.lua'))

local log            = require 'src.log'          -- single sink; NEVER create a logger here.
local settings       = require 'src.settings'
local contract       = require 'src.contract'
local writeplan      = require 'src.writeplan'
local breakerMod     = require 'src.net.breaker'
local metadata       = require 'src.metadata'
local http           = require 'src.lr.http'           -- buildDeps + uploadFile/deleteFile + attachImage
local providers      = require 'src.providers.init'    -- the GENERIC provider selector
local previewFetch   = require 'src.lr.preview_fetch'
local metadataReader = require 'src.lr.metadata_reader'
local catalogWriter  = require 'src.lr.catalog_writer'
local batcher        = require 'src.batcher'
local stagedPool     = require 'src.lr.staged_pool'     -- the SEPARATE-cap host for the deep loop
local fullresExport  = require 'src.lr.fullres_export'  -- 13-03 full-res render-to-temp glue
local sweep          = require 'src.crop.sweep'         -- PURE per-run dir + reaper primitives
local runState       = require 'src.run_state'          -- PURE OUTCOME taxonomy + outcomeFor classifier
local runStateStore  = require 'src.lr.run_state_store'  -- RETRY: cross-session run-state persistence (glue)

-- Per-invocation monotonic counter so two newRunId() calls within the SAME fractional instant (or
-- with LrDate unavailable) still get DISTINCT ids. Module-scoped so it survives across calls.
local runIdCounter = 0

-- newRunId() -> a UNIQUE, sanitize-safe run id (ONLY [%w-_] chars so sweep.sanitizeRunId accepts
-- it; NO '.'). Copied verbatim from IdentifyBirds.lua: os.time() + fractional LrDate + a per-load
-- counter, joined with '-'.
local function newRunId()
    local okT, t = pcall(os.time)
    local secs = okT and t or 0

    local frac = "0"
    local okF, f = pcall(function() return LrDate.currentTime() end)
    if okF and type(f) == 'number' and f == f then
        local s = string.format("%.4f", f)
        frac = (s:gsub("[^%d]", ""))
        if frac == "" then frac = "0" end
    end

    runIdCounter = runIdCounter + 1

    return tostring(secs) .. "-" .. frac .. "-" .. tostring(runIdCounter)
end

-- cancelled(progress) -> bool, guarded so a missing/throwing isCanceled never crashes the run.
local function cancelled(progress)
    local ok, c = pcall(function() return progress:isCanceled() end)
    return (ok and c) or false
end

-- Best-effort formatted file name for human-readable context. Never raises, never PII-leaks.
local function photoName(photo)
    local ok, name = pcall(function() return metadataReader.formattedFileName(photo) end)
    return (ok and name) or "(unknown file)"
end

-- The SHARED scratch root <temp>/BirdAID/. Every run owns a run-<id>/ subdir under it; the reaper
-- and the per-run cleanup handler both scope to this root.
local function birdaidTempRoot()
    local ok, base = pcall(function() return LrPathUtils.getStandardFilePath('temp') end)
    if not ok or type(base) ~= 'string' or base == '' then return nil end
    return LrPathUtils.child(base, 'BirdAID')
end

-- dirAgeSecs(path) -> ageSeconds | nil. Compares the dir's fileModificationDate against
-- LrDate.currentTime() (both LrDate epoch). A missing attr -> nil (treated NOT stale by the caller).
local function dirAgeSecs(path)
    local okNow, now = pcall(function() return LrDate.currentTime() end)
    if not okNow or type(now) ~= 'number' or now ~= now then return nil end
    local okAttr, attr = pcall(function() return LrFileUtils.fileAttributes(path) end)
    if not okAttr or type(attr) ~= 'table' then return nil end
    local mtime = attr.fileModificationDate
    if type(mtime) ~= 'number' then return nil end
    local age = now - mtime
    if age ~= age then return nil end
    return age
end

-- runReaper(root, ownDirName): the STARTUP REAPER. Enumerate <temp>/BirdAID/*, delete each entry
-- that sweep.isStaleRunDir(name, ageSecs, 6h) reports stale, SKIPPING this run's own dir (a
-- concurrent sibling's fresh dir is NOT swept — the age gate + isOurs prefix guarantee it). Never
-- raises; logs a token/path-free count only (T-13-13 / T-13-14).
local STALE_THRESHOLD_SECS = 6 * 3600
local function runReaper(root, ownDirName, runId)
    if type(root) ~= 'string' or root == '' then return end
    if not (LrFileUtils and LrFileUtils.exists and LrFileUtils.exists(root)) then return end
    local reaped = 0
    local okEnum, iter = pcall(function() return LrFileUtils.directoryEntries(root) end)
    if not okEnum or type(iter) ~= 'function' then return end
    -- directoryEntries yields ABSOLUTE child paths; derive the leaf name for the ownership test.
    for entryPath in iter do
        local name = LrPathUtils.leafName(entryPath)
        if name ~= ownDirName then
            local age = dirAgeSecs(entryPath)
            if type(age) == 'number' and sweep.isStaleRunDir(name, age, STALE_THRESHOLD_SECS) then
                local okDel = pcall(function() LrFileUtils.delete(entryPath) end)
                if okDel then reaped = reaped + 1 end
            end
        end
    end
    if reaped > 0 then
        log.info("deep reaper removed stale per-run dirs", { runId = runId, reaped = reaped })
    end
end

LrFunctionContext.postAsyncTaskWithContext("BirdAID.DeepIdentify", function(context)
    -- Surface unexpected (non-per-photo) failures through the standard error dialog.
    LrDialogs.attachErrorDialogToFunctionContext(context)

    local runId   = newRunId()
    local logPath = log.logFilePath()   -- best-effort, version-aware path for the user

    -- Typed prefs drive the live call + the pure plan; RAW prefs feed metadata.shape (which
    -- fail-closes the privacy toggles) and http.buildDeps.
    local rawPrefs = LrPrefs.prefsForPlugin()
    local prefs    = settings.normalizedPrefs(rawPrefs)

    -- The SEPARATE export cap (D-03): the deep loop's staged_pool concurrency, NEVER prefs.maxConcurrency.
    local exportCap = prefs.deepExportConcurrency

    local osToken = MAC_ENV and 'macos' or (WIN_ENV and 'windows' or 'unknown')

    local catalog = LrApplication.activeCatalog()
    local photos  = catalog:getTargetPhotos()
    local n       = #photos

    -- Per-run temp dir under the shared <temp>/BirdAID/ root. The run-<id> name is sanitize-safe
    -- (newRunId yields only [%w-_]); the dir cannot traverse out of the root (T-13-12, sweep V5).
    local tempRoot   = birdaidTempRoot()
    local runDirName = sweep.runDirName(runId)
    local runDir     = (tempRoot and runDirName) and LrPathUtils.child(tempRoot, runDirName) or nil

    log.info("deep run started", {
        runId = runId, targetPhotos = n, provider = prefs.provider, model = prefs.model,
        deepExportConcurrency = exportCap, dryRun = prefs.dryRun, os = osToken, logFile = logPath,
        -- deepConcurrencySpike is a deliberate RAW diagnostic flag (13-05 sweep toggle), NOT a
        -- normalized setting: it is absent from settings.DEFAULTS so normalizedPrefs drops it.
        -- Read it off rawPrefs so the flag can actually activate (H1 fix).
        spike = rawPrefs.deepConcurrencySpike == true,
    })

    if n == 0 then
        log.info("deep: no target photos -- nothing to do", { runId = runId })
        LrDialogs.message("BirdAID", "No photos available to process.")
        return
    end

    -- PROVIDER (generic, multi-provider; built ONCE for the run). A nil key / locked keychain
    -- returns a SPEAKING, token-free (nil, err): abort cleanly before any export/upload.
    local breaker = breakerMod.new()
    local deps, derr = http.buildDeps(prefs.provider, rawPrefs)
    if not deps then
        log.error("deep: provider unavailable -- run aborted before any call", {
            runId = runId, provider = prefs.provider, error = tostring(derr),
        })
        LrDialogs.message("BirdAID",
            "Cannot start deep identify: " .. tostring(derr) ..
            "\n\nSet your API key for the selected provider (" .. tostring(prefs.provider) ..
            ") in Plug-in Manager > BirdAID settings, then retry.",
            "critical")
        return
    end
    deps.breaker = breaker
    deps.runId   = runId   -- token/path-free correlation id for the upload/delete glue logs.

    local provider, perr = providers.get(prefs.provider, deps)
    if not provider then
        log.error("deep: provider not available -- run aborted before any call", {
            runId = runId, provider = prefs.provider, error = tostring(perr),
        })
        LrDialogs.message("BirdAID",
            "The selected provider (" .. tostring(prefs.provider) .. ") is not available: " ..
            tostring(perr) .. "\n\nChoose a supported provider in Plug-in Manager > BirdAID settings.",
            "critical")
        return
    end

    local progress = LrProgressScope({
        title           = "BirdAID: deep identifying birds",
        functionContext = context,   -- ties the scope lifetime to this task.
    })

    -- GUARANTEED CLEANUP (TWO handlers): progress:done() on every exit branch, AND the WHOLE
    -- per-run temp dir delete on success/error/cancel/breaker (Pattern 4 — no orphan temp survives
    -- a normal/abnormal exit; the startup reaper above reaps prior-crash orphans).
    context:addCleanupHandler(function() progress:done() end)
    context:addCleanupHandler(function()
        if type(runDir) == 'string' and runDir ~= '' then
            -- Token/path-free: NEVER log runDir (PII). Best-effort delete; absence is fine.
            pcall(function()
                if LrFileUtils and LrFileUtils.exists and LrFileUtils.exists(runDir) then
                    LrFileUtils.delete(runDir)
                end
            end)
        end
    end)
    if progress.setCancelable then progress:setCancelable(true) end

    -- STARTUP REAPER: age-gate + remove stale leftover per-run dirs (prior-crash orphans), SKIPPING
    -- this run's own dir. Runs unconditionally at run start (the reaper idiom), never raises.
    pcall(function() runReaper(tempRoot, runDirName, runId) end)

    -- The deep frame export ceiling: OpenAI sends a ~2048-equiv inline frame (D-01-OPENAI tiling);
    -- Anthropic/Gemini upload an unconstrained full-res frame by file path (maxEdge=nil).
    local isOpenAI  = (prefs.provider == 'openai')
    local exportEdge = isOpenAI and 2048 or nil

    -- ----------------------------------------------------------------------------
    -- DEEP PRODUCER/CONSUMER (the staged pool jobs). The PRODUCER renders the full-res frame
    -- SERIALLY on the main task; the CONSUMER uploads (or attaches inline) + calls the provider in
    -- its own cooperative task, BOUNDED to exportCap in flight. NO catalog write here (collect stays
    -- OUTSIDE the gate); NO base64 of a full frame on the main thread (upload streams by path).
    -- The pool keys are the photoKeys (tostring); fetchJob resolves the Lr handle from them.
    -- ----------------------------------------------------------------------------
    local photoByKey = {}
    for i = 1, n do photoByKey[tostring(photos[i])] = photos[i] end
    local indexByKey = {}
    for i = 1, n do indexByKey[tostring(photos[i])] = i end

    -- Collected per-photo records (OUTSIDE any write gate). Keyed write entries are appended in the
    -- consumer; the staged pool's status maps are advisory (we read responses straight from results).
    local results = {}
    local resultsByKey = {}

    -- deepFetch(key) -> { photo, file, index, path } | (nil, reason): MAIN-TASK serial full-res
    -- export. A render failure returns (nil, reason); the pool marks the anchor 'error' and the run
    -- continues. The raw export path lives ONLY on the job (NEVER logged).
    local function deepFetch(key)
        local photo = photoByKey[key]
        if photo == nil then return nil, 'no-photo-for-key' end
        local idx  = indexByKey[key] or 0
        local file = photoName(photo)

        if type(runDir) ~= 'string' or runDir == '' then
            return nil, 'no-temp-dir'
        end

        local path, reason = fullresExport.export(photo, {
            destDir = runDir,
            index   = idx,
            prefs   = prefs,
            maxEdge = exportEdge,
            file    = file,
            runId   = runId,
        })
        if type(path) ~= 'string' or path == '' then
            return nil, 'export:' .. tostring(reason)
        end
        return { photo = photo, file = file, index = idx, path = path, key = key }
    end

    -- deepIdentify(job) -> (status, response): the CONSUMER (parallel, gated by the pool to
    -- exportCap). It builds the deep `image` slot, calls the provider INSIDE an LrTasks.pcall, and
    -- then — in a FINALLY-EQUIVALENT block reached on BOTH the ok AND error branch — deletes any
    -- provider-side copy (D-01b). It NEVER raises (the pool's own pcall is a backstop) and records
    -- the per-photo result into the OUTSIDE-the-gate `results` collection.
    local function deepIdentify(job)
        local file = job.file
        local path = job.path

        -- Read metadata + PURE privacy-gated shape (GPS/date opt-in) for the prompt context.
        local raw = metadataReader.read(job.photo)
        local ctx = metadata.shape(raw, rawPrefs)
        ctx.runId = runId

        -- Build the deep image slot. OpenAI: inline the exported frame (attachImage reads the file
        -- by path, size-capped) + detail='high' (D-01-OPENAI). Anthropic/Gemini: upload by path ->
        -- Files-API handle (fileId/fileUri). The provider-side handle (if any) is captured here so
        -- the finally-equivalent teardown below can delete it on BOTH branches.
        local image
        local uploadHandle = nil

        if isOpenAI then
            image = { kind = 'file', path = path, detail = 'high' }   -- D-01-OPENAI high-detail tiling
            http.attachImage(image)   -- sets image.dataUrl from the file bytes (no network)
        else
            local handle, ureason = http.uploadFile(prefs.provider, path, deps)
            if handle ~= nil then
                uploadHandle = handle
                image = {
                    kind   = 'file',
                    fileId = handle.fileId,    -- Anthropic Files-API source
                    fileUri = handle.fileUri,  -- Gemini Files-API part
                }
            else
                -- Upload failed: skip this photo cleanly (token/path-free reason). No handle to delete.
                -- NEW-1: delete the per-photo exported temp JPEG BEFORE returning so a failed upload
                -- never leaks a full-res frame into the run dir until the 6h reaper (count-only log).
                if type(path) == 'string' and path ~= '' then
                    pcall(function() LrFileUtils.delete(path) end)
                end
                log.info("deep upload produced no handle (skipping identify; run continues)", {
                    runId = runId, atIndex = job.index, file = file, reason = tostring(ureason),
                })
                resultsByKey[job.key] = {
                    photoKey = job.key, photo = job.photo, response = nil,
                    error = 'upload:' .. tostring(ureason),
                    existingNames = catalogWriter.readExistingNames(job.photo),
                }
                return 'error'
            end
        end

        -- LIVE deep identify. The provider call YIELDS (LrHttp.post) -> isolate with LrTasks.pcall
        -- (yield-safe; standard pcall forbids yielding across the C-frame). ok/error are both handled
        -- below, and the provider-copy DELETE runs in a finally-equivalent block AFTER this pcall.
        local ok, det, ierr = LrTasks.pcall(function()
            return provider.identify(image, ctx)
        end)

        -- ---- FINALLY-EQUIVALENT TEARDOWN (D-01b) -------------------------------------------------
        -- Delete the Anthropic provider-side copy on BOTH the ok AND the error branch (reached
        -- whether the identify succeeded, returned (nil,err), or RAISED). This is NOT nested inside
        -- `if ok then` — it runs unconditionally after the pcall whenever a handle was created.
        -- Gemini is a no-op (48h auto-expiry); OpenAI never uploads (no handle). Token/path-free.
        if uploadHandle ~= nil then
            pcall(function() http.deleteFile(prefs.provider, uploadHandle, deps) end)
        end

        -- NEW-1: delete the per-photo EXPORTED temp JPEG in the SAME finally-equivalent teardown,
        -- reached on BOTH the ok AND the error branch (whether identify succeeded, returned (nil,err),
        -- or RAISED). Without this the full-res frames accumulate in the run dir for the whole run and
        -- survive a crash up to the 6h reaper. The end-of-run dir cleanup + reaper remain as backstops.
        -- Token/path-free: NEVER log `path` (PII); best-effort delete, absence is fine.
        if type(path) == 'string' and path ~= '' then
            pcall(function() LrFileUtils.delete(path) end)
        end

        -- ---- Classify the per-photo outcome (OUTSIDE any write gate) -----------------------------
        local det0, ierr0
        if ok then
            det0, ierr0 = det, ierr
        else
            det0, ierr0 = nil, tostring(det)   -- a raised identify: `det` carries the error message.
        end

        local previewResult, verr = nil, nil
        if det0 ~= nil then
            local vok, vmsg = contract.validateResponse(det0)
            if vok then previewResult = det0 else verr = tostring(vmsg) end
        else
            verr = tostring(ierr0)
        end

        if previewResult == nil then
            log.info("deep identify produced no usable response (skipping; run continues)", {
                runId = runId, atIndex = job.index, file = file, reason = verr or 'identify-failed',
            })
            resultsByKey[job.key] = {
                photoKey = job.key, photo = job.photo, response = nil,
                error = verr or 'identify-failed',
                existingNames = catalogWriter.readExistingNames(job.photo),
            }
            return 'error'
        end

        resultsByKey[job.key] = {
            photoKey = job.key, photo = job.photo, response = previewResult, error = nil,
            existingNames = catalogWriter.readExistingNames(job.photo),
        }
        log.info("deep identified", {
            runId = runId, atIndex = job.index, file = file,
            bird_present = previewResult.bird_present,
            detections = (previewResult.detections and #previewResult.detections) or 0,
        })
        return 'identified', previewResult
    end

    local peakConcurrency = nil

    -- H3: the pool's per-anchor terminal STATUS map, FOLDED across every poolRun (the spike sweeps
    -- multiple slices; the normal run does one pass). The assembly loop reads it to classify a photo
    -- whose record never landed as 'cancelled' / 'deferred' (honest accounting) instead of a blanket
    -- 'not-processed'. statusByAnchorKey is advisory for identified anchors (we read responses from
    -- resultsByKey) but AUTHORITATIVE for the unresolved (cancelled/deferred/error) skips.
    local statusByKey = {}

    -- poolRun(items, maxC) -> the staged driver at the SEPARATE export cap. Captures peakConcurrency
    -- AND folds the returned per-anchor status into the run-wide statusByKey map (H3).
    local function poolRun(items, maxC)
        local r = stagedPool.run({
            items          = items,
            maxConcurrency = maxC,
            fetchJob       = deepFetch,
            identifyJob    = deepIdentify,
            breaker        = breaker,
            isCanceled     = function() return cancelled(progress) end,
            spawn          = LrTasks.startAsyncTask,
            sleep          = LrTasks.sleep,
            yield          = LrTasks.yield,
            progress       = progress,
            runId          = runId,
        })
        if type(r) == 'table' and type(r.peakConcurrency) == 'number' then
            peakConcurrency = math.max(peakConcurrency or 0, r.peakConcurrency)
        end
        if type(r) == 'table' and type(r.statusByAnchorKey) == 'table' then
            for k, st in pairs(r.statusByAnchorKey) do statusByKey[k] = st end
        end
        return r
    end

    -- The pool item list is the per-photo keys in selection order.
    local items = {}
    for i = 1, n do items[i] = tostring(photos[i]) end

    -- ============================================================================
    -- SC1 EXPORT-CONCURRENCY-CLIFF SPIKE — pref-guarded (rawPrefs.deepConcurrencySpike). When OFF
    -- (default) this branch is inert and the run drives ONE poolRun at the configured exportCap.
    -- When ON, the SAME run sweeps the export cap over a fixed ladder, splitting the selection into
    -- equal slices and recording wall time + render failures + peakConcurrency per cap to the log so
    -- the 13-05 protocol can read the render cliff. NO separate harness entry, NO forbidden token.
    -- ============================================================================
    -- Raw diagnostic flag (see log-line note above): absent from settings.DEFAULTS, so it must be
    -- read off rawPrefs — normalizedPrefs would drop it and the spike could never activate (H1 fix).
    if rawPrefs.deepConcurrencySpike == true and n >= 2 then
        local ladder = { 1, 2, 3, 4 }
        local slices = #ladder
        local per = math.floor(n / slices)
        if per < 1 then per = 1 end
        local cursor = 1
        for li = 1, slices do
            if cursor > n then break end
            local capValue = ladder[li]
            local stop = (li == slices) and n or math.min(n, cursor + per - 1)
            local slice = {}
            for k = cursor, stop do slice[#slice + 1] = items[k] end
            cursor = stop + 1

            local okClock, t0 = pcall(function() return LrDate.currentTime() end)
            local r = poolRun(slice, capValue)
            local okClock2, t1 = pcall(function() return LrDate.currentTime() end)
            local wall = (okClock and okClock2 and type(t0) == 'number' and type(t1) == 'number')
                and (t1 - t0) or nil
            local renderFails = 0
            local statusMap = (type(r) == 'table' and r.statusByAnchorKey) or {}
            for _, key in ipairs(slice) do
                if statusMap[key] == 'error' then renderFails = renderFails + 1 end
            end
            log.info("deep spike slice", {
                runId = runId, cap = capValue, slice = #slice,
                wallSeconds = wall, renderFails = renderFails,
                peakConcurrency = (type(r) == 'table' and r.peakConcurrency) or nil,
            })
        end
    else
        -- NORMAL deep run: one staged pass at the configured separate export cap (D-03).
        poolRun(items, exportCap)
    end

    -- ---- ASSEMBLE the collected records (OUTSIDE any write gate) ---------------------------------
    -- Every selected photo gets a record: the consumer wrote resultsByKey[key]; a photo whose anchor
    -- never resolved gets a token-free skip so the plan counts honestly. H3: classify that skip from
    -- the pool's terminal status — 'cancelled' (user cancelled before dispatch) and 'deferred'
    -- (breaker-open) are HONEST run-level outcomes, NOT failures; anything else stays 'not-processed'.
    -- The per-outcome counts feed the summary dialog + the final log line AND the run-state persist.
    local deferredCnt  = 0    -- photos the breaker deferred (never dispatched).
    local cancelledCnt = 0    -- photos cancelled by the user (never dispatched).
    local wasCancelled = false
    for i = 1, n do
        local key = items[i]
        local rec = resultsByKey[key]
        if rec == nil then
            local st = statusByKey[key]
            local outcomeErr
            if st == 'cancelled' then
                outcomeErr = 'cancelled'; cancelledCnt = cancelledCnt + 1; wasCancelled = true
            elseif st == 'deferred' then
                outcomeErr = 'deferred'; deferredCnt = deferredCnt + 1
            else
                outcomeErr = 'not-processed'
            end
            rec = {
                photoKey = key, photo = photos[i], response = nil,
                error = outcomeErr, existingNames = {},
            }
        end
        results[#results + 1] = rec
    end

    -- ---- PLAN (pure) ----------------------------------------------------------------------------
    local report = writeplan.planReport(results, prefs)
    local perRun = report.summary.perRun

    -- ---- DRY-RUN GATE / SINGLE BATCHED APPLY ----------------------------------------------------
    local writeResult
    if report.dryRun then
        writeResult = 'dry-run'
        local entries = report.plan.entries
        local totalAdds = 0
        for ei = 1, #entries do
            local entry = entries[ei]
            local names = entry.addKeywords or {}
            totalAdds = totalAdds + #names
            log.info("DEEP DRY-RUN plan entry (would add keywords)", {
                runId = runId, atIndex = ei, photoKey = tostring(entry.photoKey),
                addCount = #names, addKeywords = table.concat(names, ", "), dryRun = true,
            })
        end
        log.info("DEEP DRY-RUN -- plan reported, writer NOT called (catalog unchanged)", {
            runId = runId, photoCount = #entries, totalKeywordsToAdd = totalAdds, dryRun = true,
        })
    else
        -- SINGLE batched write of RESULTS ONLY — NO export/upload/network inside the gate (Pitfall 2).
        -- The batcher slices at writeBatchSize (default 0 == one chunk == today's single apply); the
        -- ONLY thing entering the encapsulated catalog_writer gate is catalogWriter.apply.
        local function applyFn(plan, _chunkReport)
            return catalogWriter.apply(
                catalog,
                plan,
                "BirdAID: write bird keywords (deep)",
                { runId = runId },
                { pcall = LrTasks.pcall }
            )
        end
        local flush = batcher.flushAll(results, prefs, applyFn)
        writeResult = 'noop'
        local statuses = (type(flush) == 'table' and type(flush.statuses) == 'table') and flush.statuses or {}
        for si = 1, #statuses do
            local s = statuses[si]
            if s == 'error' then writeResult = 'error'; break end
            writeResult = s
        end
    end

    -- ---- RETRY-01: persist the per-photo TERMINAL/RETRYABLE run-state (cross-session) -------------
    -- Mirrors IdentifyBirds EXACTLY: build a { photoId = uuid, outcome } record for every collected
    -- photo via the PURE classifier run_state.outcomeFor (the SINGLE source of the status->outcome
    -- mapping — NEVER re-derived inline). photoId is the per-photo catalog uuid (stableIdFor; a
    -- nil-uuid photo is NON-RESUMABLE and dropped by save). On a non-dry-run we persist this run's
    -- state so a later run (Phase 12 retry) can re-process only the incomplete photos; on a fully
    -- successful run (no retryable photo, no breaker defer, no cancel) we clear the persisted state.
    if report.dryRun ~= true then
        -- wroteByKey[photoKey] = number of keywords PLANNED (== written on a committed apply) for this
        -- photo this run. Sourced from the authoritative whole-run plan, not inline.
        local wroteByKey = {}
        for ei = 1, #report.plan.entries do
            local e = report.plan.entries[ei]
            local names = (type(e.addKeywords) == 'table') and e.addKeywords or {}
            wroteByKey[e.photoKey] = #names
        end

        local records = {}
        local anyRetryable = false
        for ri = 1, #results do
            local rec = results[ri]
            local resp = rec.response
            -- Map the collected record to the run_state STATUS vocabulary. A response -> 'identified';
            -- otherwise the H3 run-level skips ('deferred'/'cancelled') carry through as themselves so
            -- outcomeFor classifies them retryable; any other no-response record is an 'errored' retry.
            local status
            if type(resp) == 'table' then
                status = 'identified'
            elseif rec.error == 'deferred' then
                status = 'deferred'
            elseif rec.error == 'cancelled' then
                status = 'cancelled'
            else
                status = 'errored'
            end
            local birdPresent = (type(resp) == 'table') and resp.bird_present or nil
            local detectionCount = (type(resp) == 'table' and type(resp.detections) == 'table')
                and #resp.detections or 0
            local outcome = runState.outcomeFor({
                status         = status,
                birdPresent    = birdPresent,
                detectionCount = detectionCount,
                wroteCount     = wroteByKey[rec.photoKey] or 0,
            })
            if outcome ~= nil then
                if not runState.isTerminal(outcome) then anyRetryable = true end
                records[#records + 1] = {
                    photoId = runStateStore.stableIdFor(rec.photo),   -- uuid or nil (NON-RESUMABLE)
                    outcome = outcome,
                }
            end
        end

        -- Fully successful (nothing to resume) only when no photo is retryable AND nothing was
        -- deferred/cancelled at the run level. Otherwise persist the incomplete-set.
        local fullyDone = (not anyRetryable) and (deferredCnt == 0) and (cancelledCnt == 0)
            and (not wasCancelled)
        if fullyDone then
            pcall(function() runStateStore.clear() end)
        else
            pcall(function() runStateStore.save(runId, records) end)
        end
    end

    local bstate = breaker.state()
    log.info("deep run finished", {
        runId = runId, total = n, photos = perRun.photos,
        cancelled = wasCancelled, deferred = deferredCnt, cancelledPhotos = cancelledCnt,
        breakerOpen = bstate.open, breakerConsecutive = bstate.consecutive,
        found = perRun.found, identified = perRun.identified, uncertain = perRun.uncertain,
        errors = perRun.errors, skipped = perRun.skipped,
        provider = prefs.provider, deepExportConcurrency = exportCap,
        peakConcurrency = peakConcurrency,
        dryRun = report.dryRun, writeResult = writeResult, logFile = logPath,
    })

    local headline = string.format(
        "Deep: %d photo(s); found %d, identified %d, uncertain %d, errors %d, skipped %d.",
        n, perRun.found, perRun.identified, perRun.uncertain, perRun.errors, perRun.skipped)

    local message = headline
        .. "\n\nprovider: " .. tostring(prefs.provider)
        .. "  |  model: " .. tostring(prefs.model)
        .. "  |  dryRun: " .. tostring(report.dryRun)
        .. "\nwriteResult: " .. tostring(writeResult)
        .. "  |  breaker open: " .. tostring(bstate.open)
        .. "  |  export cap: " .. tostring(exportCap)
        .. "  |  deferred: " .. tostring(deferredCnt)
        .. (peakConcurrency and ("  |  peak concurrency: " .. tostring(peakConcurrency)) or "")
        .. ((cancelledCnt > 0) and ("  |  cancelled: " .. tostring(cancelledCnt)) or "")
        .. (wasCancelled and "  (cancelled)" or "")
        .. "\n\nDetails are in the BirdAID log:\n" .. logPath

    local kind = (perRun.errors > 0 or writeResult == 'error' or bstate.open) and "warning" or "info"
    LrDialogs.message("BirdAID", message, kind)
end)
