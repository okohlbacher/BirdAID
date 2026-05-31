-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/IdentifyBirds.lua (HARD-01 + Phase 9 — the real shipping menu command)
--
-- The menu entry point Lightroom invokes from Library > Plug-in Extras > "Identify
-- Birds in Selected Photos...". This is the REAL end-to-end pipeline for the USER'S
-- SELECTED provider (openai / claude / gemini): it runs
--   settings -> http.buildDeps(prefs.provider) -> providers.get(prefs.provider, deps)
--   -> per-photo (preview + metadata + identify)
--   -> writeplan.planReport -> dry-run-log OR a single batched catalog_writer.apply.
--
-- It hangs off the proven lifecycle:
--   * Runs inside LrFunctionContext.postAsyncTaskWithContext so the UI thread never
--     blocks and cleanup/error handlers are context-bound.
--   * Reports the count of catalog:getTargetPhotos() it will act on.
--   * Drives a context-bound LrProgressScope; cancel is honored via progress:isCanceled()
--     checked at the TOP of every iteration (and around the inter-photo wait).
--   * Isolates per-photo failures with LrTasks.pcall so a failing photo never aborts the
--     run; tracks HONEST processed/errors/cancelled/deferred counters.
--   * Guarantees progress:done() runs on normal completion,
--     cancel, AND unexpected error via context:addCleanupHandler.
--
-- ===========================================================================
-- PHASE 9 (BL-06 parallel / BL-07 cluster / BL-04 report) — DEFAULT-SAFE HARD BYPASS
-- ===========================================================================
-- The three Phase-9 features ship OFF by default. The #1 invariant (orchestrate.featuresOff):
--   maxConcurrency==1 AND clusterBursts==false AND showDetectionReport==false
--     => the EXISTING SERIAL CODE PATH runs VERBATIM and the worker_pool / clustering /
--        jpeg_thumb / similarity / results.build / viz_report modules are NEVER required,
--        constructed, or called. The pure orchestrate helper + the e2e spy spec assert this.
-- Only on the FEATURE branch (some feature on) does the orchestrator:
--   (0) sweep prior reports UNCONDITIONALLY at run start (mirrors the crop orphan-sweep);
--   (1) optional cluster pre-pass (clusterBursts) -> anchors + follower->anchor map;
--   (2) dispatch ANCHORS via the staged pool (serial preview fetch + parallel gated AI), CONSUME
--       its returned { statusByAnchorKey, responseByAnchorKey };
--   (3) results.build -> one per-photo result for EVERY selected photo;
--   (3b) results->writeplan ADAPTER (photoKey->handle + PER-PHOTO existingNames, NEVER inherited);
--   (4) the EXISTING writeplan.planReport -> dry-run-log OR the single batched apply (UNCHANGED);
--   (5) optional detection report (showDetectionReport), post-collect, OUTSIDE the gate.
-- The feature requires are LAZY (only reached on the feature branch) so the bypass never loads them.
--
-- PROVIDER (generic, multi-provider): deps are built ONCE via http.buildDeps(prefs.provider)
-- (one Keychain read, model reconciled to the selected provider) and the provider is
-- resolved via providers.get(prefs.provider, deps). The SAME provider instance is reused
-- for the preview identify. We deliberately avoid the OpenAI-hardcoded provider constructor,
-- which would ignore prefs.provider.
--
-- CLOUD-NATIVE / CROSS-PLATFORM: detection (bird_present + bbox) AND species are produced by the
-- provider from the (downsampled) preview. There is no local or full-res crop pass and no external
-- image tool, so BirdAID runs on Windows as well as macOS. NOTE: the downsampled preview image IS
-- uploaded to the selected third-party AI for identification.
--
-- This file imports Lr* (it is the orchestration entry) but it does NOT create its own
-- logger -- ALL logging routes through the single src.log sink (single-sink invariant), and
-- it NEVER logs the API token, "Bearer", the request body / data URL, GPS, date, or the raw
-- path -- only the FORMATTED filename + token-free counts.
--
-- Strictly Lua 5.1 common subset (no goto, no //, no \u{}).

local LrApplication     = import 'LrApplication'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'
local LrTasks           = import 'LrTasks'
local LrDialogs         = import 'LrDialogs'
local LrPathUtils       = import 'LrPathUtils'
local LrPrefs           = import 'LrPrefs'
local LrDate            = import 'LrDate'

-- Install the src.* module loader shim BEFORE any require of our modules: LrC's built-in
-- require cannot resolve dotted/subdirectory names. dofile is the documented escape hatch.
dofile(LrPathUtils.child(_PLUGIN.path, 'birdaid_bootstrap.lua'))

local log            = require 'src.log'          -- single sink; NEVER create a logger here.
local settings       = require 'src.settings'
local contract       = require 'src.contract'
local writeplan      = require 'src.writeplan'
local breakerMod     = require 'src.net.breaker'
local metadata       = require 'src.metadata'
local orchestrate    = require 'src.orchestrate'       -- PURE Wave-3 composition (bypass predicate + adapter)
local http           = require 'src.lr.http'           -- the SHARED generic Lr glue (ALL providers)
local providers      = require 'src.providers.init'    -- the GENERIC provider selector
local previewFetch   = require 'src.lr.preview_fetch'
local metadataReader = require 'src.lr.metadata_reader'
local catalogWriter  = require 'src.lr.catalog_writer'

-- Per-invocation monotonic counter so even two newRunId() calls within the SAME fractional
-- instant (or with LrDate unavailable) still get DISTINCT ids. Module-scoped so it survives
-- across calls within a single plugin load.
local runIdCounter = 0

-- newRunId() -> a UNIQUE, sanitize-safe run id. os.time() alone shares a temp dir across
-- same-second runs, so we combine three sources, joined with '-' (ONLY [%w-_] chars so
-- sweep.sanitizeRunId accepts it; NO '.' which sanitizeRunId rejects):
--   * os.time()              -- Unix wall-clock seconds (coarse).
--   * LrDate.currentTime()   -- fractional seconds; the decimal point is stripped to keep the
--                               id sanitize-safe, so two runs in the same second still differ.
--   * runIdCounter           -- a monotonic per-load counter as a final disambiguator.
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

LrFunctionContext.postAsyncTaskWithContext("BirdAID.IdentifyBirds", function(context)
    -- Surface unexpected (non-per-photo) failures through the standard error dialog.
    LrDialogs.attachErrorDialogToFunctionContext(context)

    local runId   = newRunId()
    local logPath = log.logFilePath()   -- best-effort, version-aware path for the user

    -- Typed prefs drive the live call + the pure plan; RAW prefs feed metadata.shape (which
    -- fail-closes the privacy toggles).
    local rawPrefs    = LrPrefs.prefsForPlugin()
    local prefs       = settings.normalizedPrefs(rawPrefs)
    local maxEdge     = prefs.previewSize

    -- PHASE 9: the HARD default-safe bypass predicate (PURE). When true, NONE of the feature
    -- modules are required/constructed/called -- the existing serial loop runs verbatim below.
    local featuresOff = orchestrate.featuresOff(prefs)

    -- OS token (MAC_ENV/WIN_ENV are LrC globals) for the structured run log only. Detection +
    -- species are fully cloud-side, so BirdAID is cross-platform (no external tools / no crop).
    local osToken = MAC_ENV and 'macos' or (WIN_ENV and 'windows' or 'unknown')

    local catalog = LrApplication.activeCatalog()
    local photos  = catalog:getTargetPhotos()
    local n       = #photos

    log.info("run started", {
        runId = runId, targetPhotos = n, provider = prefs.provider, model = prefs.model,
        previewSize = maxEdge, dryRun = prefs.dryRun, os = osToken, logFile = logPath,
        -- token-free Phase-9 mode counters.
        maxConcurrency = prefs.maxConcurrency, clusterBursts = prefs.clusterBursts,
        showDetectionReport = prefs.showDetectionReport, featuresOff = featuresOff,
    })

    if n == 0 then
        log.info("no target photos -- nothing to do", { runId = runId })
        LrDialogs.message("BirdAID", "No photos available to process.")
        return
    end

    -- PROVIDER (generic, multi-provider; built ONCE for the run). buildDeps does the ONE
    -- per-provider Keychain read + per-provider auth header + model reconcile to prefs.provider.
    -- A nil key / locked keychain returns a SPEAKING, token-free (nil, err): abort cleanly.
    local breaker = breakerMod.new()
    local deps, derr = http.buildDeps(prefs.provider, rawPrefs)
    if not deps then
        log.error("provider unavailable -- run aborted before any call", {
            runId = runId, provider = prefs.provider, error = tostring(derr),
        })
        LrDialogs.message("BirdAID",
            "Cannot start: " .. tostring(derr) ..
            "\n\nSet your API key for the selected provider (" .. tostring(prefs.provider) ..
            ") in Plug-in Manager > BirdAID settings, then retry.",
            "critical")
        return
    end
    -- Inject the run-level breaker into the deps so the provider records ok/fatal/exhausted.
    deps.breaker = breaker

    local provider, perr = providers.get(prefs.provider, deps)
    if not provider then
        log.error("provider not available -- run aborted before any call", {
            runId = runId, provider = prefs.provider, error = tostring(perr),
        })
        LrDialogs.message("BirdAID",
            "The selected provider (" .. tostring(prefs.provider) .. ") is not available: " ..
            tostring(perr) .. "\n\nChoose a supported provider in Plug-in Manager > BirdAID settings.",
            "critical")
        return
    end

    -- (No crop pass: detection + species are fully cloud-side from the preview — cross-platform,
    -- no external image tool. The previous EXPERIMENTAL macOS-only crop-for-ID was removed.)

    local progress = LrProgressScope({
        title           = "BirdAID: identifying birds",
        functionContext = context,   -- ties the scope lifetime to this task.
    })

    -- GUARANTEED CLEANUP: done() runs on normal completion, cancel, AND unexpected error.
    context:addCleanupHandler(function() progress:done() end)
    if progress.setCancelable then progress:setCancelable(true) end

    -- ===========================================================================
    -- SHARED per-photo identify body. Split so previews are NEVER fetched concurrently:
    --   * fetchJob(photo, atIndex)        -> the MAIN-TASK preview fetch + metadata shape -> job.
    --   * identifyAfterFetch(job, atIndex) -> the provider call on the preview -> (response, err).
    --   * identifyOnePhoto(photo, atIndex) -> serial composition (used by the default-safe bypass).
    -- The parallel path runs fetchJob on the main task (serial) and identifyAfterFetch in a gated
    -- consumer. NO catalog write here (collect stays OUTSIDE the gate) and NO breaker-defer decision
    -- (the provider owns the breaker; the worker_gate re-reads shouldStop before the provider call).
    -- ===========================================================================
    -- fetchJob(photo, atIndex) -> { image, ctx, file } | (nil, reason). The MAIN-TASK, SERIAL
    -- preview fetch + metadata shaping, DECOUPLED from the provider call. The parallel path runs
    -- this on the orchestrator's task (never from N worker coroutines), so it never issues
    -- concurrent requestJpegThumbnail renders — which time out under load (the stress-test bug).
    local function fetchJob(photo, atIndex)
        local file = photoName(photo)

        -- ---- Preview fetch -------------------------------------------------
        local transport, reason = previewFetch.fetch(photo, maxEdge, {
            isCanceled = function() return cancelled(progress) end,
            file       = file,
            runId      = runId,
        })
        if not transport then
            log.info("preview not ready (skipping identify; run continues)", {
                runId = runId, atIndex = atIndex, file = file, reason = tostring(reason),
            })
            return nil, "preview:" .. tostring(reason)
        end

        -- ---- Metadata read + PURE shape (privacy-gated) -------------------
        local raw = metadataReader.read(photo)
        local ctx = metadata.shape(raw, rawPrefs)
        ctx.runId = runId

        -- ---- Build the transport image (provider-agnostic) ---------------
        local previewImage = {
            kind = transport.kind, data = transport.data,
            width = transport.width, height = transport.height,
        }
        http.attachImage(previewImage)
        return { image = previewImage, ctx = ctx, file = file }
    end

    -- identifyAfterFetch(job, atIndex) -> (response, err). The provider call on the (downsampled)
    -- preview. In the parallel path the CONSUMER wraps this in the worker_gate (after-token
    -- cancel/breaker); the serial bypass calls it directly. Detection + species are fully cloud-side.
    local function identifyAfterFetch(job, atIndex)
        local file = job.file
        local ctx = job.ctx
        local previewImage = job.image

        -- ---- LIVE identify on the preview (generic provider) -------------
        local det, ierr = provider.identify(previewImage, ctx)

        -- RE-validate (defence in depth). A degrade {bird_present=false} is valid.
        local previewResult, verr = nil, nil
        if det ~= nil then
            local vok, vmsg = contract.validateResponse(det)
            if vok then previewResult = det else verr = tostring(vmsg) end
        else
            verr = tostring(ierr)
        end

        if previewResult == nil then
            log.info("identify produced no usable response (skipping; run continues)", {
                runId = runId, atIndex = atIndex, file = file, reason = verr or 'identify-failed',
            })
            return nil, verr or 'identify-failed'
        end

        -- Cloud-native: the provider does detection + species from the (downsampled) preview. There
        -- is no local/full-res crop pass (removed for cross-platform; ImageMagick was macOS-only).
        return previewResult, nil
    end

    -- identifyOnePhoto(photo, atIndex): SERIAL composition (fetch on this task, then identify).
    -- Used by the default-safe bypass loop. The parallel path does NOT use this; it calls fetchJob
    -- on the main task and identifyAfterFetch in a gated worker (so previews aren't fetched together).
    local function identifyOnePhoto(photo, atIndex)
        local job, reason = fetchJob(photo, atIndex)
        if job == nil then return nil, reason end
        return identifyAfterFetch(job, atIndex)
    end

    -- ---- COLLECT PHASE (entirely OUTSIDE any write gate) ----------------------
    local results      = {}
    local wasCancelled = false
    local deferred     = 0    -- photos skipped after the breaker opened / deferred clusters.
    local cancelledCnt = 0    -- photos cancelled (feature branch reports this; serial folds into break).
    local reportNote   = nil  -- set when the detection report was suppressed (too many to open).

    -- The REAL dispatch decision lives in orchestrate.dispatch (spec-driven): at defaults it runs
    -- runSerial and NEVER runFeatures, so the feature modules' LAZY requires (inside runFeatures)
    -- never load. Any feature ON runs runFeatures (the spec-tested orchestrate.runFeatures sequence).
    orchestrate.dispatch({
        featuresOff = featuresOff,
        runSerial = function()
        -- =======================================================================
        -- DEFAULT-SAFE HARD BYPASS — the EXISTING serial loop, VERBATIM. NO feature module is
        -- required or called here (orchestrate.featuresOff guaranteed all features are off).
        -- =======================================================================
        for i, photo in ipairs(photos) do
            if cancelled(progress) then
                wasCancelled = true
                log.info("cancelled by user", { runId = runId, atIndex = i, total = n })
                break
            end

            progress:setPortionComplete(i - 1, n)
            progress:setCaption(string.format("Photo %d of %d", i, n))

            local photoKey = tostring(photo)

            local ok, errOrResp = LrTasks.pcall(function()
                local resp, ierr = identifyOnePhoto(photo, i)
                if resp == nil then
                    results[#results + 1] = {
                        photoKey = photoKey, photo = photo, response = nil,
                        error = ierr or 'identify-failed',
                        existingNames = catalogWriter.readExistingNames(photo),
                    }
                    return
                end
                results[#results + 1] = {
                    photoKey = photoKey, photo = photo, response = resp, error = nil,
                    existingNames = catalogWriter.readExistingNames(photo),
                }
                log.info("identified", {
                    runId = runId, atIndex = i, file = photoName(photo),
                    bird_present = resp.bird_present,
                    detections = (resp.detections and #resp.detections) or 0,
                })
            end)

            if not ok then
                results[#results + 1] = {
                    photoKey = photoKey, photo = photo, response = nil,
                    error = tostring(errOrResp), existingNames = {},
                }
                log.error("photo processing failed (isolated; run continues)", {
                    runId = runId, atIndex = i, error = tostring(errOrResp),
                })
            end

            -- ---- Run-level breaker: defer the remainder after a sustained outage ----
            if breaker.shouldStop() then
                local remaining = n - i
                if remaining > 0 then
                    deferred = remaining
                    log.warn("breaker open -- deferring remaining photos (run-level cooldown)", {
                        runId = runId, atIndex = i, deferred = deferred,
                        breaker = breaker.state().consecutive,
                    })
                end
                break
            end

            LrTasks.yield()   -- cooperative: keep the UI responsive.
        end
        end,   -- runSerial
        runFeatures = function()
        -- =======================================================================
        -- FEATURE BRANCH (some Phase-9 feature is ON). LAZY-require the feature modules ONLY
        -- here so the bypass never loads them.
        -- =======================================================================
        local workerGate = require 'src.net.worker_gate'   -- PURE per-provider-call gate (cancel/breaker).
        local clusterGroup = require 'src.cluster.group'
        local jpegThumb = require 'src.cluster.jpeg_thumb'
        local similarity = require 'src.cluster.similarity'
        local resultsMod = require 'src.results'
        local stagedPool = require 'src.lr.staged_pool'   -- staged producer/consumer (preview decoupled)
        local stackReader = require 'src.lr.stack_reader'
        local vizReport = require 'src.lr.viz_report'

        -- (0) RUN-START SWEEPS: the report orphan-sweep runs UNCONDITIONALLY (should-fix E) —
        -- NOT gated on showDetectionReport — mirroring the crop sweep, so prior report-enabled
        -- runs' dirs cannot leak across later report-disabled runs.
        pcall(function() vizReport.sweepOrphans(runId) end)

        -- Build the per-photo handle map (tostring keys, MATCHING orchestrate.runFeatures'
        -- photoKeyOf=tostring) so identifyFn can resolve an anchor key -> Lr handle.
        local photoByKey = {}
        for i = 1, #photos do photoByKey[tostring(photos[i])] = photos[i] end

        -- Real-time wall clock for the gate (seconds; NOT CPU time).
        local function wallClock()
            local ok, t = pcall(function() return LrDate.currentTime() end)
            if ok and type(t) == 'number' and t == t then return t end
            return os.time()
        end

        -- producerFetch(anchorKey) -> job | (nil, reason): MAIN-TASK serial preview fetch (the
        -- reliable, one-render-at-a-time path). Stamps job.atIndex for the identify-side logs.
        local function producerFetch(anchorKey)
            local photo = photoByKey[anchorKey]
            if photo == nil then return nil, 'no-photo-for-anchor' end
            local job, reason = fetchJob(photo, anchorKey)
            if job == nil then return nil, reason end
            job.atIndex = anchorKey
            return job
        end

        -- consumerIdentify(job) -> (status, response): the CONSUMER (parallel AI call). The
        -- worker_gate applies the after-token cancel/breaker gate immediately before the provider
        -- call. There is no token bucket (no rate-limit knob) -> bucket nil = unlimited; provider
        -- 429s are handled by the provider's backoff + the run-level breaker.
        local function consumerIdentify(job)
            local status, resp = workerGate.gate({
                item       = job,
                now        = wallClock,
                sleep      = LrTasks.sleep,
                isCanceled = function() return cancelled(progress) end,
                breaker    = breaker,
                identify   = function(it) return identifyAfterFetch(it, it.atIndex) end,
            })
            return status, resp
        end

        -- poolRun(anchors) -> { statusByAnchorKey, responseByAnchorKey }: the STAGED driver fetches
        -- previews SERIALLY on this (main) task and parallelizes only the gated provider call,
        -- bounded to maxConcurrency in flight. This fixes the concurrent-preview-timeout bug.
        local function poolRun(anchors)
            return stagedPool.run({
                items          = anchors,
                maxConcurrency = prefs.maxConcurrency,
                fetchJob       = producerFetch,
                identifyJob    = consumerIdentify,
                breaker        = breaker,
                isCanceled     = function() return cancelled(progress) end,
                spawn          = LrTasks.startAsyncTask,
                sleep          = LrTasks.sleep,
                yield          = LrTasks.yield,
                progress       = progress,
                runId          = runId,
            })
        end

        -- fetchGrid(photo,i): >=128px thumb bytes -> PURE DC-luma grid (nil => not similar => no
        -- merge, the SAFE direction). Guarded; logs the token-free stack-key probe for Task 12.
        local function fetchGrid(photo, i)
            local file = photoName(photo)
            local grid = nil
            local okFetch, bytes = LrTasks.pcall(function()
                return previewFetch.fetchThumbBytes(photo, 128, {
                    isCanceled = function() return cancelled(progress) end,
                    -- clustering is BEST-EFFORT: a thumbnail miss just skips clustering for this
                    -- photo (it becomes its own anchor), so use a SHORT timeout and don't block the
                    -- whole pre-pass waiting on a cold render.
                    timeoutMs = 8000,
                    file = file, runId = runId,
                })
            end)
            if okFetch and type(bytes) == 'string' and bytes ~= '' then
                local okGrid, g = pcall(function() return jpegThumb.dcLumaGrid(bytes) end)
                if okGrid then grid = g end
            end
            local okProbe, probe = pcall(function() return stackReader.probe(photo) end)
            if okProbe and type(probe) == 'table' and type(probe.keysWithValues) == 'table'
                and #probe.keysWithValues > 0 then
                log.info("stack-key probe (clustering)", {
                    runId = runId, atIndex = i, file = file,
                    stackKeys = table.concat(probe.keysWithValues, ","),
                })
            end
            return grid
        end

        -- DRIVE THE REAL PURE SEQUENCE: buildFrames -> optional cluster -> poolRun(anchors) ->
        -- results.build -> per-photo adapter. This is the SAME orchestrate.runFeatures the e2e spec
        -- drives, so the entry's actual dispatch is what the spec covers (blockers A/B + adapter).
        local fr = orchestrate.runFeatures({
            prefs       = prefs,
            photos      = photos,
            photoKeyOf  = tostring,
            timeEpochOf = function(p) return stackReader.captureTimeEpoch(p) end,
            stackIdOf   = function(p)
                if prefs.clusterBursts ~= true then return nil end
                return stackReader.stackId(p)
            end,
            fetchGrid    = fetchGrid,
            similarGrids = function(a, b)
                return similarity.similar(a, b, prefs.clusterSimilarityThreshold)
            end,
            group        = clusterGroup.group,
            poolRun      = poolRun,
            resultsBuild = resultsMod.build,
            readExistingNames = function(handle)
                local ok, names = LrTasks.pcall(function()
                    return catalogWriter.readExistingNames(handle)
                end)
                return (ok and type(names) == 'table') and names or {}
            end,
        })
        results      = fr.results
        deferred     = fr.deferred
        cancelledCnt = fr.cancelled
        if cancelledCnt and cancelledCnt > 0 then wasCancelled = true end

        log.info("collect done (feature branch)", {
            runId = runId, total = n, identified = fr.identified,
            deferred = fr.deferred, cancelled = fr.cancelled, errored = fr.errored,
            anchors = fr.anchors, followers = fr.followers,
        })

        -- (5) OPTIONAL DETECTION REPORT (showDetectionReport, NOT dry-run). Post-collect, OUTSIDE
        -- the gate. The orphan-sweep already ran UNCONDITIONALLY at step 0 -- do NOT re-sweep here.
        -- Guarded per photo; never blocks the run; cancel-aware.
        if prefs.showDetectionReport == true and prefs.dryRun ~= true then
            -- The report opens ONE browser tab per detected photo. Count eligible photos FIRST and
            -- SUPPRESS the entire report above a small cap, so a bulk run never floods the browser
            -- with dozens/hundreds of tabs (BL-13: a single combined gallery is the proper fix).
            local REPORT_OPEN_LIMIT = 20
            local eligible = 0
            for ei = 1, #fr.results do
                local r = fr.results[ei]
                if type(r.response) == 'table' and type(r.response.detections) == 'table'
                    and #r.response.detections > 0 then
                    eligible = eligible + 1
                end
            end
            if eligible > REPORT_OPEN_LIMIT then
                reportNote = string.format(
                    "Detection report not opened: %d photos have detections (limit %d). "
                    .. "Re-run on a smaller selection to view the report.",
                    eligible, REPORT_OPEN_LIMIT)
                log.warn("detection report suppressed (too many to open)", {
                    runId = runId, eligible = eligible, limit = REPORT_OPEN_LIMIT,
                })
            else
                local repIdx = 0
                for ei = 1, #fr.results do
                    if cancelled(progress) then break end
                    local entry = fr.results[ei]
                    local resp = entry.response
                    if type(resp) == 'table' and type(resp.detections) == 'table'
                        and #resp.detections > 0 then
                        repIdx = repIdx + 1
                        local photo = entry.photo
                        local file = photoName(photo)
                        -- Re-fetch the small preview bytes + dims for the report (OUTSIDE the gate).
                        -- YIELD-SAFE: previewFetch.fetch yields (LrTasks.sleep) and vizReport.writeAndOpen
                        -- may LrTasks.execute (open) — both yield across a C frame, so this MUST be the
                        -- yield-safe LrTasks.pcall, NEVER a standard C pcall (Lua 5.1 forbids yielding
                        -- across a standard pcall boundary).
                        LrTasks.pcall(function()
                            local transport = previewFetch.fetch(photo, maxEdge, {
                                isCanceled = function() return cancelled(progress) end,
                                file = file, runId = runId,
                            })
                            local bytes, fw, fh
                            if type(transport) == 'table' then
                                bytes = transport.data; fw = transport.width; fh = transport.height
                            end
                            vizReport.writeAndOpen({
                                runId = runId, idx = repIdx, previewBytes = bytes,
                                frameW = fw, frameH = fh, response = resp, prefs = prefs, file = file,
                            })
                        end)
                    end
                end
            end
        end
        end,   -- runFeatures
    })

    -- ---- PLAN (pure) ----------------------------------------------------------
    local report = writeplan.planReport(results, prefs)
    local perRun = report.summary.perRun

    -- ---- DRY-RUN GATE / SINGLE BATCHED APPLY ----------------------------------
    local writeResult
    if report.dryRun then
        -- Report ONLY. NEVER call the writer (catalog unchanged, no Undo step).
        writeResult = 'dry-run'
        local entries = report.plan.entries
        local totalAdds = 0
        for ei = 1, #entries do
            local entry = entries[ei]
            local names = entry.addKeywords or {}
            totalAdds = totalAdds + #names
            log.info("DRY-RUN plan entry (would add keywords)", {
                runId = runId, atIndex = ei, photoKey = tostring(entry.photoKey),
                addCount = #names, addKeywords = table.concat(names, ", "), dryRun = true,
            })
        end
        log.info("DRY-RUN -- plan reported, writer NOT called (catalog unchanged)", {
            runId = runId, photoCount = #entries, totalKeywordsToAdd = totalAdds, dryRun = true,
        })
    else
        writeResult = catalogWriter.apply(
            catalog,
            report.plan,
            "BirdAID: write bird keywords",
            { runId = runId },
            { pcall = LrTasks.pcall }   -- yield-safe outer gate wrap (withWriteAccessDo yields)
        )
    end

    local bstate = breaker.state()
    -- [CODEX #N1] HONEST counts: report the AUTHORITATIVE per-run summary from writeplan
    -- (found / identified / uncertain / errors / skipped). Token-free: only counts + flags.
    log.info("run finished", {
        runId = runId, total = n, photos = perRun.photos,
        cancelled = wasCancelled, deferred = deferred, cancelledPhotos = cancelledCnt,
        breakerOpen = bstate.open, breakerConsecutive = bstate.consecutive,
        found = perRun.found, identified = perRun.identified, uncertain = perRun.uncertain,
        errors = perRun.errors, skipped = perRun.skipped,
        featuresOff = featuresOff, maxConcurrency = prefs.maxConcurrency,
        clusterBursts = prefs.clusterBursts, showDetectionReport = prefs.showDetectionReport,
        dryRun = report.dryRun, writeResult = writeResult, logFile = logPath,
    })

    -- HONEST final report dialog.
    local headline = string.format(
        "%d photo(s); found %d, identified %d, uncertain %d, errors %d, skipped %d.",
        n, perRun.found, perRun.identified, perRun.uncertain, perRun.errors, perRun.skipped)

    local message = headline
        .. "\n\nprovider: " .. tostring(prefs.provider)
        .. "  |  model: " .. tostring(prefs.model)
        .. "  |  dryRun: " .. tostring(report.dryRun)
        .. "\nwriteResult: " .. tostring(writeResult)
        .. "  |  breaker open: " .. tostring(bstate.open)
        .. "  |  deferred: " .. tostring(deferred)
        .. ((cancelledCnt > 0) and ("  |  cancelled: " .. tostring(cancelledCnt)) or "")
        .. (wasCancelled and "  (cancelled)" or "")
        .. (reportNote and ("\n\n" .. reportNote) or "")
        .. "\n\nDetails are in the BirdAID log:\n" .. logPath

    local kind = (perRun.errors > 0 or writeResult == 'error' or bstate.open) and "warning" or "info"
    LrDialogs.message("BirdAID", message, kind)
end)
