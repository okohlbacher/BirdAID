-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/IdentifyBirds.lua (HARD-01 — the real shipping menu command)
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

    -- ---- COLLECT PHASE (entirely OUTSIDE any write gate) ----------------------
    local results      = {}
    local processed    = 0    -- photos whose body completed (preview fetched + identify attempted).
    local errors       = 0    -- isolated per-photo failures.
    local wasCancelled = false
    local deferred     = 0    -- photos skipped after the breaker opened.
    local cropsRun     = 0
    local cropsSkipped = 0

    for i, photo in ipairs(photos) do
        if cancelled(progress) then
            wasCancelled = true
            log.info("cancelled by user", { runId = runId, atIndex = i, processed = processed, total = n })
            break
        end

        progress:setPortionComplete(i - 1, n)
        progress:setCaption(string.format("Photo %d of %d", i, n))

        -- Capture a photoKey BEFORE the pcall body so a collect failure still records an error.
        local photoKey = tostring(photo)

        local ok, err = LrTasks.pcall(function()
            local file = photoName(photo)

            -- ---- Preview fetch -------------------------------------------------
            local transport, reason = previewFetch.fetch(photo, maxEdge, {
                isCanceled = function() return cancelled(progress) end,
                file       = file,
                runId      = runId,
            })
            if not transport then
                results[#results + 1] = {
                    photoKey      = photoKey,
                    photo         = photo,
                    response      = nil,
                    error         = "preview:" .. tostring(reason),
                    existingNames = catalogWriter.readExistingNames(photo),
                }
                log.info("preview not ready (skipping identify; run continues)", {
                    runId = runId, atIndex = i, file = file, reason = tostring(reason),
                })
                return
            end

            -- ---- Metadata read + PURE shape (privacy-gated) -------------------
            local raw = metadataReader.read(photo)
            local ctx = metadata.shape(raw, rawPrefs)
            ctx.runId = runId

            -- ---- LIVE identify on the preview (generic provider) -------------
            -- http.attachImage sets BOTH image.dataUrl (OpenAI) AND image.b64 (Claude/Gemini),
            -- so ANY selected provider works off the same image.
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
                results[#results + 1] = {
                    photoKey      = photoKey,
                    photo         = photo,
                    response      = nil,
                    error         = verr or 'identify-failed',
                    existingNames = catalogWriter.readExistingNames(photo),
                }
                log.info("identify produced no usable response (skipping; run continues)", {
                    runId = runId, atIndex = i, file = file, reason = verr or 'identify-failed',
                })
                return
            end

            -- ---- OPT-IN EXPERIMENTAL PER-DETECTION CROP PASS -----------------
            -- Only when cropActive AND a bird is present AND the crop tool validates.
            local finalResult = previewResult
            if cropActive
                and previewResult.bird_present
                and type(previewResult.detections) == 'table'
                and #previewResult.detections > 0 then

                local toolOk = false
                local okTool, toolWhy = cropper.validateToolPath(prefs.imageToolPath)
                toolOk = okTool and true or false
                if not toolOk then
                    log.info("crop tool unavailable (skipping crop pass; using preview)", {
                        runId = runId, atIndex = i, file = file, reason = tostring(toolWhy),
                    })
                else
                    -- Export the full-res frame ONCE per photo (crop input + exact ref dims).
                    local exportPath, eerr = cropper.exportFullRes(photo, runId, i)
                    if not exportPath then
                        log.warn("export failed (degrading to preview; run continues)", {
                            runId = runId, atIndex = i, file = file, reason = tostring(eerr),
                        })
                    else
                        local exportW, exportH = cropper.exportDims(exportPath)
                        if not exportW then
                            log.warn("export dims unreadable (degrading to preview)", {
                                runId = runId, atIndex = i, file = file, reason = tostring(exportH),
                            })
                        else
                            local cropPerDetection = {}
                            for di, d in ipairs(previewResult.detections) do
                                local rect, rerr = bboxTransform.transform(
                                    d.bbox, exportW, exportH, { maxEdge = maxCropEdge })
                                if not rect then
                                    cropsSkipped = cropsSkipped + 1
                                    log.warn("bbox transform failed (keeping preview detection)", {
                                        runId = runId, atIndex = i, detection = di,
                                        file = file, reason = tostring(rerr),
                                    })
                                else
                                    local cropPath, crErr = cropper.runCrop(
                                        prefs.imageToolPath, exportPath, rect,
                                        runId, di, file, maxCropEdge)
                                    if not cropPath then
                                        cropsSkipped = cropsSkipped + 1
                                        log.info("crop step degraded (keeping preview detection)", {
                                            runId = runId, atIndex = i, detection = di,
                                            file = file, reason = tostring(crErr),
                                        })
                                    else
                                        -- Re-query the SAME provider on the crop (kind='file').
                                        local cropImage = {
                                            kind   = 'file',
                                            path   = cropPath,
                                            width  = rect.w,
                                            height = rect.h,
                                        }
                                        http.attachImage(cropImage)
                                        local cropResp, cqErr = provider.identify(cropImage, ctx)
                                        local refined
                                        if cropResp ~= nil then
                                            local cvok, cvmsg = contract.validateResponse(cropResp)
                                            if cvok and cropResp.bird_present
                                                and type(cropResp.detections) == 'table'
                                                and cropResp.detections[1] ~= nil then
                                                refined = cropResp.detections[1]
                                            else
                                                log.info("crop re-query unusable (keeping preview)", {
                                                    runId = runId, atIndex = i, detection = di,
                                                    file = file, reason = tostring(cvmsg),
                                                })
                                            end
                                        else
                                            log.info("crop re-query returned no response", {
                                                runId = runId, atIndex = i, detection = di,
                                                file = file, reason = tostring(cqErr),
                                            })
                                        end

                                        if refined ~= nil then
                                            cropPerDetection[di] = refined
                                            cropsRun = cropsRun + 1
                                        else
                                            cropsSkipped = cropsSkipped + 1
                                        end
                                    end
                                end
                            end

                            -- PER-DETECTION merge: retains ALL preview detections; replaces one
                            -- only when its confident-rank refinement >= the preview's.
                            finalResult = merge.merge(previewResult, cropPerDetection, threshold)
                        end
                    end
                end
            end

            results[#results + 1] = {
                photoKey      = photoKey,
                photo         = photo,
                response      = finalResult,
                error         = nil,
                existingNames = catalogWriter.readExistingNames(photo),
            }
            processed = processed + 1

            log.info("identified", {
                runId = runId, atIndex = i, file = file,
                bird_present = finalResult.bird_present,
                detections = (finalResult.detections and #finalResult.detections) or 0,
            })
        end)

        if not ok then
            errors = errors + 1
            -- Append an error result so the pure writeplan counts this photo as an error.
            results[#results + 1] = {
                photoKey      = photoKey,
                photo         = photo,
                response      = nil,
                error         = tostring(err),
                existingNames = {},
            }
            log.error("photo processing failed (isolated; run continues)", {
                runId = runId, atIndex = i, error = tostring(err),
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
    -- (found / identified / uncertain / errors / skipped). The loop-local `processed`
    -- counter undercounted (it incremented only on a fully-completed body, so a photo whose
    -- preview/identify failed showed processed=0 while errors=1). We surface perRun.* as the
    -- single source of truth and keep `photos` == the photos the writeplan actually tallied,
    -- so the line cannot self-contradict. Token-free: only counts + flags.
    log.info("run finished", {
        runId = runId, total = n, photos = perRun.photos,
        cancelled = wasCancelled, deferred = deferred,
        breakerOpen = bstate.open, breakerConsecutive = bstate.consecutive,
        found = perRun.found, identified = perRun.identified, uncertain = perRun.uncertain,
        errors = perRun.errors, skipped = perRun.skipped,
        cropsRun = cropsRun, cropsSkipped = cropsSkipped,
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
        .. (wasCancelled and "  (cancelled)" or "")
        .. (cropNote and ("\n\nNote: " .. tostring(cropNote)) or "")
        .. "\n\nDetails are in the BirdAID log:\n" .. logPath

    local kind = (perRun.errors > 0 or writeResult == 'error' or bstate.open) and "warning" or "info"
    LrDialogs.message("BirdAID", message, kind)
end)
