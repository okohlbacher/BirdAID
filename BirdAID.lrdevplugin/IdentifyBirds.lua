-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/IdentifyBirds.lua (HARD-01 + Phase 9 — the real shipping menu command)
--
-- The menu entry point Lightroom invokes from Library > Plug-in Extras > "Identify
-- Birds in Selected Photos...". This is the REAL end-to-end pipeline for the USER'S
-- SELECTED provider (openai / claude / gemini): it runs
--   settings -> http.buildDeps(prefs.provider) -> providers.get(prefs.provider, deps)
--   -> per-photo (preview + metadata + identify [+ optional EXPERIMENTAL crop])
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
--   * Guarantees progress:done() (and the crop-dir cleanup) runs on normal completion,
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
--   (2) dispatch ANCHORS via worker_pool.run (shared capacity-1 token bucket + breaker), CONSUME
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
-- for the preview identify AND every crop re-query. We deliberately avoid the
-- OpenAI-hardcoded provider constructor, which would ignore prefs.provider.
--
-- CROP-for-ID ships OFF by default AND is EXPERIMENTAL: it runs only when prefs.cropEnabled
-- AND platform.capabilities(osToken).crop_supported (macOS) AND the external tool validates,
-- and only after an explicit EXPERIMENTAL warning is logged (the 06-03 spike is still open).
-- Off-macOS the crop command is NEVER built; the fail-clear reason is logged + surfaced.
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
local platform       = require 'src.platform'
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
local cropper        = require 'src.lr.cropper'
local bboxTransform  = require 'src.crop.bbox_transform'
local merge          = require 'src.crop.merge'

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
    local rateLimit   = prefs.rateLimit
    local maxCropEdge = prefs.maxCropEdge
    local threshold   = prefs.confidenceThreshold

    -- PHASE 9: the HARD default-safe bypass predicate (PURE). When true, NONE of the feature
    -- modules are required/constructed/called -- the existing serial loop runs verbatim below.
    local featuresOff = orchestrate.featuresOff(prefs)

    -- Platform-capability decision (pure): MAC_ENV/WIN_ENV are LrC globals -> an OS token ->
    -- capabilities. Off-macOS crop_supported is false with a clear, surfaceable reason.
    local osToken = MAC_ENV and 'macos' or (WIN_ENV and 'windows' or 'unknown')
    local caps    = platform.capabilities(osToken)

    local catalog = LrApplication.activeCatalog()
    local photos  = catalog:getTargetPhotos()
    local n       = #photos

    log.info("run started", {
        runId = runId, targetPhotos = n, provider = prefs.provider, model = prefs.model,
        rateLimit = rateLimit, previewSize = maxEdge, dryRun = prefs.dryRun,
        cropEnabled = prefs.cropEnabled, os = osToken, logFile = logPath,
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

    -- CROP GATE (EXPERIMENTAL until the 06-03 spike is closed). crop ships OFF by default.
    -- [CODEX #3] cropActive requires the external tool to VALIDATE UP FRONT (mirrors the
    -- Phase-6 tool-check-before-export fix in the dev crop spike entry): it is true ONLY when
    -- prefs.cropEnabled AND the platform supports crop AND cropper.validateToolPath(...) is
    -- OK. If the tool is missing/invalid we do NOT create the run temp dir and do NOT claim
    -- "crop ran" — crop is inactive, the pipeline uses the preview, and the experimental
    -- "ran" notice is NEVER falsely emitted. validateToolPath returns a token-free reason.
    local cropPlatformOk = caps.crop_supported and true or false
    local cropToolOk     = false
    local cropToolWhy    = nil
    if prefs.cropEnabled == true and cropPlatformOk then
        local okTool, whyTool = cropper.validateToolPath(prefs.imageToolPath)
        cropToolOk  = okTool and true or false
        cropToolWhy = whyTool
    end
    local cropActive = (prefs.cropEnabled == true) and cropPlatformOk and cropToolOk
    local cropNote   = nil   -- a token-free note surfaced in the final summary, if any.

    if prefs.cropEnabled == true then
        -- Always emit the explicit EXPERIMENTAL warning BEFORE any crop step is set up.
        log.warn("crop-for-ID is EXPERIMENTAL/unverified (pending the 06-03 spike); macOS + a VALIDATED external crop tool only", {
            runId = runId, os = osToken,
        })
        if not cropPlatformOk then
            -- Fail clear off-macOS: log the reason, surface it, and build NO crop command.
            cropNote = caps.crop_reason
            log.warn("crop requested but unsupported on this platform -- skipping crop (preview only)", {
                runId = runId, os = osToken, reason = tostring(caps.crop_reason),
            })
        elseif not cropToolOk then
            -- [CODEX #3] Tool missing/invalid UP FRONT: crop is NOT active. NO temp dir, NO
            -- false "crop ran" claim. Token-free reason (validateToolPath never leaks a path).
            cropNote = "crop disabled: external image tool missing or invalid"
            log.warn("crop requested but the external image tool did not validate -- skipping crop (preview only)", {
                runId = runId, os = osToken, reason = tostring(cropToolWhy),
            })
        else
            cropNote = "crop-for-ID ran in EXPERIMENTAL mode (unverified pending 06-03)"
        end
    end

    -- Per-run owned temp dir + whole-dir cleanup on success/error/CANCEL -- ONLY when cropActive.
    if cropActive then
        local runDir, rderr = cropper.runDir(runId)
        if not runDir then
            -- Could not create the crop dir: degrade to preview-only rather than abort the run.
            log.warn("could not create per-run crop temp dir -- continuing preview only", {
                runId = runId, reason = tostring(rderr),
            })
            cropActive = false
            cropNote = "crop disabled: could not create temp dir"
        else
            context:addCleanupHandler(function() cropper.cleanupRunDir(runId) end)
            cropper.sweepOrphans(runId)   -- age-gated; deletes OTHER stale run-* dirs only.
        end
    end

    local progress = LrProgressScope({
        title           = "BirdAID: identifying birds",
        functionContext = context,   -- ties the scope lifetime to this task.
    })

    -- GUARANTEED CLEANUP: done() runs on normal completion, cancel, AND unexpected error.
    context:addCleanupHandler(function() progress:done() end)
    if progress.setCancelable then progress:setCancelable(true) end

    -- ===========================================================================
    -- SHARED per-photo identify body (used by BOTH the serial bypass loop AND the
    -- feature-branch worker_pool identifyFn). It runs preview fetch + metadata + provider
    -- identify (+ optional crop re-query) and returns (response, nil) | (nil, err). It performs
    -- NO catalog write (collect stays OUTSIDE the gate) and NO breaker-defer decision (the
    -- provider owns the breaker; the serial loop reads shouldStop after; the worker_pool gate
    -- re-reads shouldStop before each provider call). `atIndex` is for logging only.
    --
    -- `cropGate` (FEATURE BRANCH ONLY) routes each crop re-query provider call through the SAME
    -- pure worker_gate.gate(...) sequence as the preview call (acquire token -> after-token
    -- isCanceled? -> after-token breaker.shouldStop? -> else provider.identify). It is
    -- cropGate(cropImage, ctx) -> (status, response, err) with status one of
    -- 'identified'|'cancelled'|'deferred'|'fatal'. A nil cropGate (the DEFAULT-SAFE BYPASS path,
    -- featuresOff) keeps today's EXACT serial crop behavior: the crop re-query is the direct,
    -- ungated provider.identify call. A crop-call 'cancelled'/'deferred' MUST propagate (we abort
    -- the per-photo identify with that reason) -- it is NEVER silently downgraded to an ungated call.
    -- ===========================================================================
    local function identifyOnePhoto(photo, atIndex, cropGate)
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

        -- ---- LIVE identify on the preview (generic provider) -------------
        local previewImage = {
            kind = transport.kind, data = transport.data,
            width = transport.width, height = transport.height,
        }
        http.attachImage(previewImage)
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

        -- ---- OPT-IN EXPERIMENTAL PER-DETECTION CROP PASS -----------------
        local finalResult = previewResult
        if cropActive
            and previewResult.bird_present
            and type(previewResult.detections) == 'table'
            and #previewResult.detections > 0 then

            local okTool, toolWhy = cropper.validateToolPath(prefs.imageToolPath)
            if not (okTool and true or false) then
                log.info("crop tool unavailable (skipping crop pass; using preview)", {
                    runId = runId, atIndex = atIndex, file = file, reason = tostring(toolWhy),
                })
            else
                local exportPath, eerr = cropper.exportFullRes(photo, runId, atIndex)
                if not exportPath then
                    log.warn("export failed (degrading to preview; run continues)", {
                        runId = runId, atIndex = atIndex, file = file, reason = tostring(eerr),
                    })
                else
                    local exportW, exportH = cropper.exportDims(exportPath)
                    if not exportW then
                        log.warn("export dims unreadable (degrading to preview)", {
                            runId = runId, atIndex = atIndex, file = file, reason = tostring(exportH),
                        })
                    else
                        local cropPerDetection = {}
                        for di, d in ipairs(previewResult.detections) do
                            local rect, rerr = bboxTransform.transform(
                                d.bbox, exportW, exportH, { maxEdge = maxCropEdge })
                            if not rect then
                                log.warn("bbox transform failed (keeping preview detection)", {
                                    runId = runId, atIndex = atIndex, detection = di,
                                    file = file, reason = tostring(rerr),
                                })
                            else
                                local cropPath, crErr = cropper.runCrop(
                                    prefs.imageToolPath, exportPath, rect,
                                    runId, di, file, maxCropEdge)
                                if not cropPath then
                                    log.info("crop step degraded (keeping preview detection)", {
                                        runId = runId, atIndex = atIndex, detection = di,
                                        file = file, reason = tostring(crErr),
                                    })
                                else
                                    -- Re-query the SAME provider on the crop (kind='file').
                                    -- FEATURE BRANCH: route the crop provider call through the SAME
                                    -- worker_gate.gate(...) sequence as the preview call (cropGate),
                                    -- so it acquires its own token and re-checks isCanceled/breaker.
                                    -- shouldStop IMMEDIATELY before the call. A 'cancelled'/'deferred'
                                    -- gate outcome PROPAGATES (aborts this photo) — it is NEVER
                                    -- silently downgraded to an ungated provider call. BYPASS PATH
                                    -- (cropGate==nil): EXACT today's serial ungated direct call.
                                    local cropImage = {
                                        kind = 'file', path = cropPath,
                                        width = rect.w, height = rect.h,
                                    }
                                    http.attachImage(cropImage)
                                    local cropResp, cqErr
                                    if cropGate ~= nil then
                                        local status, gResp, gErr = cropGate(cropImage, ctx)
                                        if status == 'cancelled' or status == 'deferred' then
                                            -- Propagate: the gate refused this provider call. Surface
                                            -- it as the per-photo error so the driver classifies the
                                            -- WHOLE item with this terminal reason (never an ungated
                                            -- fall-back). 'cancelled' -> cancel; 'deferred' -> breaker.
                                            log.info("crop re-query gate refused provider call (propagating)", {
                                                runId = runId, atIndex = atIndex, detection = di,
                                                file = file, reason = status,
                                            })
                                            return nil, status
                                        end
                                        -- 'identified' carries the response; 'fatal' carries gErr.
                                        cropResp, cqErr = gResp, gErr
                                    else
                                        cropResp, cqErr = provider.identify(cropImage, ctx)
                                    end
                                    local refined
                                    if cropResp ~= nil then
                                        local cvok, cvmsg = contract.validateResponse(cropResp)
                                        if cvok and cropResp.bird_present
                                            and type(cropResp.detections) == 'table'
                                            and cropResp.detections[1] ~= nil then
                                            refined = cropResp.detections[1]
                                        else
                                            log.info("crop re-query unusable (keeping preview)", {
                                                runId = runId, atIndex = atIndex, detection = di,
                                                file = file, reason = tostring(cvmsg),
                                            })
                                        end
                                    else
                                        log.info("crop re-query returned no response", {
                                            runId = runId, atIndex = atIndex, detection = di,
                                            file = file, reason = tostring(cqErr),
                                        })
                                    end
                                    if refined ~= nil then
                                        cropPerDetection[di] = refined
                                    end
                                end
                            end
                        end
                        finalResult = merge.merge(previewResult, cropPerDetection, threshold)
                    end
                end
            end
        end

        return finalResult, nil
    end

    -- ---- COLLECT PHASE (entirely OUTSIDE any write gate) ----------------------
    local results      = {}
    local wasCancelled = false
    local deferred     = 0    -- photos skipped after the breaker opened / deferred clusters.
    local cancelledCnt = 0    -- photos cancelled (feature branch reports this; serial folds into break).

    if featuresOff then
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

            -- ---- Inter-photo rate limit (sleep AFTER each photo EXCEPT the last) ----
            if i < n then
                if cancelled(progress) then
                    wasCancelled = true
                    log.info("cancelled before inter-photo wait", { runId = runId, atIndex = i })
                    break
                end
                if type(rateLimit) == 'number' and rateLimit > 0 then
                    LrTasks.sleep(rateLimit)
                end
                if cancelled(progress) then
                    wasCancelled = true
                    log.info("cancelled after inter-photo wait", { runId = runId, atIndex = i })
                    break
                end
            end

            LrTasks.yield()   -- cooperative: keep the UI responsive.
        end
    else
        -- =======================================================================
        -- FEATURE BRANCH (some Phase-9 feature is ON). LAZY-require the feature modules ONLY
        -- here so the bypass never loads them.
        -- =======================================================================
        local tokenBucket = require 'src.net.token_bucket'
        local workerGate = require 'src.net.worker_gate'   -- PURE per-provider-call gate (crop re-query).
        local clusterGroup = require 'src.cluster.group'
        local jpegThumb = require 'src.cluster.jpeg_thumb'
        local similarity = require 'src.cluster.similarity'
        local resultsMod = require 'src.results'
        local workerPool = require 'src.lr.worker_pool'
        local stackReader = require 'src.lr.stack_reader'
        local vizReport = require 'src.lr.viz_report'

        -- (0) RUN-START SWEEPS: the report orphan-sweep runs UNCONDITIONALLY (should-fix E) —
        -- NOT gated on showDetectionReport — mirroring the crop sweep, so prior report-enabled
        -- runs' dirs cannot leak across later report-disabled runs.
        pcall(function() vizReport.sweepOrphans(runId) end)

        -- (1) OPTIONAL cluster pre-pass + photoByKey (always built for the adapter).
        local framing = orchestrate.buildFrames({
            photos      = photos,
            photoKeyOf  = tostring,
            timeEpochOf = function(p) return stackReader.captureTimeEpoch(p) end,
            stackIdOf   = function(p)
                if prefs.clusterBursts ~= true then return nil end
                return stackReader.stackId(p)
            end,
        })
        local photoByKey = framing.photoByKey
        local selection = framing.selection

        local anchors, followerToAnchor
        if prefs.clusterBursts == true then
            -- Per-photo >=128px thumbnail -> PURE DC-luma 8x8 grid, cached by key. A nil grid =>
            -- not similar (no merge), the SAFE direction. Guarded per-photo; never aborts the run.
            local gridByKey = {}
            for i = 1, #photos do
                local photo = photos[i]
                local key = tostring(photo)
                local file = photoName(photo)
                local okFetch, bytes = LrTasks.pcall(function()
                    return previewFetch.fetchThumbBytes(photo, 128, {
                        isCanceled = function() return cancelled(progress) end,
                        file = file, runId = runId,
                    })
                end)
                if okFetch and type(bytes) == 'string' and bytes ~= '' then
                    local okGrid, grid = pcall(function() return jpegThumb.dcLumaGrid(bytes) end)
                    if okGrid then gridByKey[key] = grid end
                end
                -- Log the stack-key probe (token-free) so the live Task-12 pass reveals real keys.
                local okProbe, probe = pcall(function() return stackReader.probe(photo) end)
                if okProbe and type(probe) == 'table' and type(probe.keysWithValues) == 'table'
                    and #probe.keysWithValues > 0 then
                    log.info("stack-key probe (clustering)", {
                        runId = runId, atIndex = i, file = file,
                        stackKeys = table.concat(probe.keysWithValues, ","),
                    })
                end
            end

            local sim = function(prevKey, curKey)
                return similarity.similar(gridByKey[prevKey], gridByKey[curKey],
                    prefs.clusterSimilarityThreshold)
            end
            local grp = clusterGroup.group(framing.frames, {
                maxGapSeconds = prefs.clusterMaxGapSeconds,
                useStacks     = prefs.clusterUseStacks,
                sim           = sim,
            })
            anchors = grp.anchors
            followerToAnchor = grp.followerToAnchor
        else
            -- Clustering off (but another feature on): every photo is its own anchor.
            anchors = {}
            for i = 1, #selection do anchors[#anchors + 1] = selection[i] end
            followerToAnchor = {}
        end

        log.info("cluster pre-pass done", {
            runId = runId, total = n, anchors = #anchors,
            followers = (function() local c = 0; for _ in pairs(followerToAnchor) do c = c + 1 end; return c end)(),
            clustering = prefs.clusterBursts,
        })

        -- (2) DISPATCH the ANCHORS via the pool. The token bucket gates EVERY provider call
        -- (capacity=1, no bursting). rate = 1/rateLimit tokens/sec (rateLimit<=0 => unlimited).
        local rate = (type(rateLimit) == 'number' and rateLimit > 0) and (1 / rateLimit) or 0
        local bucket = tokenBucket.new({ rate = rate, capacity = 1, now0 = 0 })

        -- Wall clock for the SHARED bucket: a monotonically-advancing real-time seconds value (NOT
        -- CPU time), matching worker_pool's wallClockSeconds so the crop re-query gate and the
        -- preview gate consume from the SAME bucket against the SAME advancing clock.
        local function cropWallClock()
            local ok, t = pcall(function() return LrDate.currentTime() end)
            if ok and type(t) == 'number' and t == t then return t end
            return os.time()
        end

        -- CROP RE-QUERY GATE (FEATURE BRANCH ONLY): each crop provider call goes through the SAME
        -- pure worker_gate.gate sequence as the preview call — acquire ONE token from the shared
        -- bucket, re-check isCanceled (cancel WINS), re-check breaker.shouldStop (READ-ONLY; the
        -- provider owns record), else call provider.identify(cropImage, ctx). Returns the gate's
        -- plain (status, response, err); identifyOnePhoto propagates 'cancelled'/'deferred'.
        local function cropGate(cropImage, ctx)
            return workerGate.gate({
                item       = cropImage,
                bucket     = bucket,
                now        = cropWallClock,
                sleep      = LrTasks.sleep,
                isCanceled = function() return cancelled(progress) end,
                breaker    = breaker,
                identify   = function() return provider.identify(cropImage, ctx) end,
            })
        end

        -- identifyFn for an anchor key -> (response, err). Look up the Lr handle from photoByKey;
        -- the worker_gate wraps THIS (outermost) call with the per-call token + after-token
        -- shouldStop gate; the threaded cropGate gates EACH crop re-query the same way.
        local function identifyFn(anchorKey)
            local photo = photoByKey[anchorKey]
            if photo == nil then return nil, 'no-photo-for-anchor' end
            return identifyOnePhoto(photo, anchorKey, cropGate)
        end

        local poolOut = workerPool.run({
            items          = anchors,
            maxConcurrency = prefs.maxConcurrency,
            bucket         = bucket,
            breaker        = breaker,
            identifyFn     = identifyFn,
            onCollect      = function() end,   -- responseByAnchorKey is the canonical store.
            progress       = progress,
            isCanceled     = function() return cancelled(progress) end,
            pcall          = LrTasks.pcall,
            runId          = runId,
        })

        -- (3) BUILD PER-PHOTO RESULTS — consume worker_pool.run's RETURN (blocker A).
        local resModel = resultsMod.build({
            selection        = selection,
            anchors          = anchors,
            followerToAnchor = followerToAnchor,
            anchorStatus     = poolOut.statusByAnchorKey,
            anchorResponse   = poolOut.responseByAnchorKey,
        })

        -- (3b) RESULTS->WRITEPLAN ADAPTER (blocker B) — PER-PHOTO existingNames, NEVER inherited.
        -- The read runs OUTSIDE the write gate (a catalog read), wrapped so a throwing read
        -- degrades that photo to empty-existing rather than aborting.
        local adapter = orchestrate.buildAdapterEntries({
            ordered    = resModel.ordered,
            photoByKey = photoByKey,
            readExistingNames = function(handle)
                local ok, names = LrTasks.pcall(function()
                    return catalogWriter.readExistingNames(handle)
                end)
                return (ok and type(names) == 'table') and names or {}
            end,
        })
        results  = adapter.entries
        deferred = adapter.deferred
        cancelledCnt = adapter.cancelled
        if cancelledCnt > 0 then wasCancelled = true end

        log.info("collect done (feature branch)", {
            runId = runId, total = n, identified = adapter.identified,
            deferred = adapter.deferred, cancelled = adapter.cancelled, errored = adapter.errored,
        })

        -- (5) OPTIONAL DETECTION REPORT (showDetectionReport, NOT dry-run). Post-collect, OUTSIDE
        -- the gate. The orphan-sweep already ran UNCONDITIONALLY at step 0 -- do NOT re-sweep here.
        -- Guarded per photo; never blocks the run; cancel-aware.
        if prefs.showDetectionReport == true and prefs.dryRun ~= true then
            local repIdx = 0
            for ei = 1, #adapter.entries do
                if cancelled(progress) then break end
                local entry = adapter.entries[ei]
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
        .. (cropNote and ("\n\nNote: " .. tostring(cropNote)) or "")
        .. "\n\nDetails are in the BirdAID log:\n" .. logPath

    local kind = (perRun.errors > 0 or writeResult == 'error' or bstate.open) and "warning" or "info"
    LrDialogs.message("BirdAID", message, kind)
end)
